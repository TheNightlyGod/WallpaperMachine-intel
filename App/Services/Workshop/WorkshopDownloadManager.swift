import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class WorkshopDownload: Identifiable {
  /// Why a queued job has not started yet.
  enum Hold {
    /// Every download slot is taken.
    case slot
    /// A running job is still signing in; its outcome decides whether the saved sign-in works,
    /// and prompts must not pile up.
    case signIn
    /// Sessions cannot share a sign-in (**Keep me signed in** is off, or Steam allows this
    /// account one session), so jobs run one after another.
    case previous
  }

  let id: String
  let item: WorkshopItem?
  let account: String
  let worker: WorkshopDownloader
  fileprivate(set) var isQueued = true
  fileprivate(set) var isPaused = false
  fileprivate(set) var hold = Hold.slot
  fileprivate var occupiesSlot = false
  fileprivate var wasCancelled = false
  /// Set once Steam ended this session for another sign-in and the manager put it back in line.
  fileprivate(set) var retriesAfterSessionConflict = false
  let rememberSession: Bool
  @ObservationIgnored fileprivate var begin: (() -> Void)?

  var isPending: Bool { isQueued || occupiesSlot }
  var isCancelled: Bool { wasCancelled || worker.wasCancelled }
  var status: String {
    if isPaused { return String(localized: "Download paused") }
    if isQueued {
      if retriesAfterSessionConflict {
        return String(localized: "Steam allows one session at a time for this account; waiting to retry")
      }
      switch hold {
      case .slot: return String(localized: "Waiting for a free download slot")
      case .signIn: return String(localized: "Waiting for the current sign-in to finish")
      case .previous: return String(localized: "Waiting for the previous download")
      }
    }
    if wasCancelled { return String(localized: "Download cancelled") }
    return worker.status
  }
  /// A job back in line for an automatic retry carries no failure; the retry decides.
  var errorMessage: String? { isQueued ? nil : worker.errorMessage }
  var phase: WorkshopDownloader.Phase? { isQueued ? nil : worker.phase }
  var progress: Double? { isQueued ? nil : worker.progress }
  var bytesReceived: Int64? { isQueued ? nil : worker.bytesReceived }
  var bytesExpected: Int64? { isQueued ? nil : worker.bytesExpected }
  var bytesPerSecond: Double? { isQueued ? nil : worker.bytesPerSecond }
  var secondsRemaining: Int? { isQueued ? nil : worker.secondsRemaining }

  /// A job that only signs in and downloads nothing.
  var isSignIn: Bool { id == WorkshopDownloadManager.signInID }

  fileprivate init(
    id: String, item: WorkshopItem?, account: String, rememberSession: Bool,
    sessionDirectory: URL, runtimeProvider: any SteamCMDRuntimeProviding, checkpointDirectory: URL? = nil,
    networkMonitor: (any ProcessNetworkMonitoring)? = nil
  ) {
    self.id = id
    self.item = item
    self.account = account
    self.rememberSession = rememberSession
    worker = WorkshopDownloader(
      sessionDirectory: sessionDirectory, runtimeProvider: runtimeProvider,
      networkMonitor: networkMonitor, checkpointDirectory: checkpointDirectory)
  }
}

/// Runs several private SteamCMD sessions at once, each with its own copy of the saved sign-in.
///
/// Sign-in is the one thing sessions cannot do side by side: a batch signs in once, through
/// whichever job is at the front, and the rest wait until Steam accepts it (the worker saves the
/// session at that moment, not only at the end) and then start silently from the saved sign-in.
/// Without a saved sign-in to share — **Keep me signed in** off — jobs run one after another,
/// each with its own prompt. If Steam ends a session because the same account signed in from
/// another of our sessions, the ended job goes back in line once and the queue stays serial for
/// the rest of the app's run.
@MainActor
@Observable
final class WorkshopDownloadManager: SteamCMDDownloadActivity {
  nonisolated static let defaultConcurrentDownloads = 3
  /// The choices Settings offers. More sessions mean more Steam sign-ins per minute, so the
  /// ceiling stays at what a real account has been seen to sustain.
  nonisolated static let concurrentDownloadRange = 1...6
  /// Id of the sign-in-only job; there is at most one, like the shared-assets job.
  static let signInID = "steam-sign-in"

  private(set) var downloads: [WorkshopDownload] = []
  private(set) var savedAccount: String?
  private(set) var errorMessage: String?
  /// Steam refused to keep two of our sessions signed in at once, so the queue is serial.
  private(set) var sessionConflictDetected = false
  /// The user's ceiling; `slotLimit` is what applies right now.
  private(set) var maximumConcurrentDownloads: Int
  @ObservationIgnored private let sessionDirectory: URL
  @ObservationIgnored private let runtimeProvider: any SteamCMDRuntimeProviding
  @ObservationIgnored private let networkMonitorFactory: (@MainActor () -> any ProcessNetworkMonitoring)?
  @ObservationIgnored private var isShuttingDown = false
  @ObservationIgnored private var persistenceDirectory: URL?
  @ObservationIgnored private let wakeCenter: NotificationCenter
  @ObservationIgnored private var wakeObserver: NSObjectProtocol?

  private struct SavedDownload: Codable {
    let id: String
    let item: WorkshopItem?
    let account: String
    let rememberSession: Bool
  }

  /// Configured by the app store, separate from Steam's replaceable sign-in directory.
  func configurePersistence(at directory: URL) {
    guard persistenceDirectory == nil else { return }
    persistenceDirectory = directory
    guard downloads.isEmpty, let data = try? Data(contentsOf: directory.appendingPathComponent("queue.json")),
      let saved = try? JSONDecoder().decode([SavedDownload].self, from: data)
    else { return }
    var seen = Set<String>()
    for record in saved where record.id != Self.signInID && seen.insert(record.id).inserted {
      guard record.id == "scene-assets" || (record.item?.id == record.id && record.id.allSatisfy(\.isNumber)),
        WorkshopDownloader.normalizedAccount(record.account) != nil else { continue }
      let job = WorkshopDownload(id: record.id, item: record.item, account: record.account,
        rememberSession: record.rememberSession, sessionDirectory: sessionDirectory,
        runtimeProvider: runtimeProvider, checkpointDirectory: checkpointDirectory(for: record.id),
        networkMonitor: networkMonitorFactory?())
      job.isQueued = false
      job.isPaused = true
      downloads.append(job)
    }
  }

  private func checkpointDirectory(for id: String) -> URL? {
    guard id != Self.signInID else { return nil }
    return persistenceDirectory?.appendingPathComponent(id, isDirectory: true)
  }

  @discardableResult
  private func persist() -> Bool {
    guard let directory = persistenceDirectory else { return true }
    let saved = downloads.filter { !$0.isSignIn && !$0.isCancelled && ($0.isPending || $0.isPaused || $0.errorMessage != nil) }.map {
      SavedDownload(id: $0.id, item: $0.item, account: $0.account, rememberSession: $0.rememberSession)
    }
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      // Checkpoints below this folder are partial downloads of several gigabytes.
      ClientPaths.excludeFromBackup(directory)
      try JSONEncoder().encode(saved).write(to: directory.appendingPathComponent("queue.json"), options: .atomic)
      return true
    } catch {
      errorMessage = String(localized: "Could not save the download queue: \(error.localizedDescription)")
      return false
    }
  }

  var activeCount: Int { downloads.lazy.filter { $0.occupiesSlot }.count }
  var queuedCount: Int { downloads.lazy.filter { $0.isQueued }.count }
  var isRunning: Bool { downloads.contains { $0.isPending } }
  /// The bytes received and expected of each download that is moving or waiting its turn, for the
  /// menu bar's one line about them. A job being paused is already out of it, while it still
  /// holds its slot, and so is the sign-in that downloads nothing.
  var inProgressTransfers: [(received: Int64?, expected: Int64?)] {
    downloads.filter { $0.isPending && !$0.isPaused && !$0.isSignIn }.map { ($0.bytesReceived, $0.bytesExpected) }
  }
  /// How many transfers may run side by side right now.
  var slotLimit: Int { sessionConflictDetected ? 1 : maximumConcurrentDownloads }
  var suggestedAccount: String? { downloads.last(where: { $0.isPending })?.account ?? savedAccount }
  var rememberSessionWhileRunning: Bool? {
    downloads.first(where: { $0.isPending })?.rememberSession
  }

  init(
    sessionDirectory: URL = ClientPaths.steamSessionURL(),
    runtimeProvider: any SteamCMDRuntimeProviding = SteamCMDRuntimeService(),
    maximumConcurrentDownloads: Int = WorkshopDownloadManager.defaultConcurrentDownloads,
    networkMonitorFactory: (@MainActor () -> any ProcessNetworkMonitoring)? = nil,
    wakeCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
  ) {
    self.sessionDirectory = sessionDirectory
    self.runtimeProvider = runtimeProvider
    self.networkMonitorFactory = networkMonitorFactory
    self.wakeCenter = wakeCenter
    self.maximumConcurrentDownloads = Self.clampedConcurrentDownloads(maximumConcurrentDownloads)
    savedAccount = WorkshopDownloader.readSavedAccount(at: sessionDirectory)
    // A connection often dies with the sleep; each running transfer checks that bytes still arrive.
    wakeObserver = wakeCenter.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.systemDidWake() }
    }
  }

  /// A manager that is dropped without `shutdown()` (every test builds one) must not leave its
  /// observer on the shared workspace center for the rest of the process.
  deinit {
    if let wakeObserver { wakeCenter.removeObserver(wakeObserver) }
  }

  private func systemDidWake() {
    for job in downloads where job.occupiesSlot { job.worker.noteSystemResume() }
  }

  func download(for itemID: String?) -> WorkshopDownload? {
    downloads.first { $0.id == (itemID ?? "scene-assets") }
  }

  /// Raising the ceiling starts queued work at once; lowering it lets running transfers finish
  /// and only holds back what has not started yet.
  func setMaximumConcurrentDownloads(_ count: Int) {
    let next = Self.clampedConcurrentDownloads(count)
    guard next != maximumConcurrentDownloads else { return }
    maximumConcurrentDownloads = next
    AppLog.info("Workshop downloads may now run \(next) at a time")
    startQueuedDownloads()
  }

  private static func clampedConcurrentDownloads(_ count: Int) -> Int {
    min(max(count, concurrentDownloadRange.lowerBound), concurrentDownloadRange.upperBound)
  }

  var signIn: WorkshopDownload? { downloads.first { $0.id == Self.signInID } }

  func start(
    item: WorkshopItem, username: String, executable: URL, library: URL,
    rememberSession: Bool = true, onImported: @escaping @MainActor () async throws -> Void
  ) {
    enqueue(id: item.id, item: item, username: username, rememberSession: rememberSession) { worker, account in
      worker.start(
        item: item, username: account, executable: executable, library: library,
        rememberSession: rememberSession, onImported: onImported)
    }
  }

  func installAssets(
    username: String, executable: URL, destination: URL, rememberSession: Bool = true,
    onInstalled: @escaping @MainActor () throws -> Void
  ) {
    enqueue(id: "scene-assets", item: nil, username: username, rememberSession: rememberSession) { worker, account in
      worker.installAssets(
        username: account, executable: executable, destination: destination,
        rememberSession: rememberSession, onInstalled: onInstalled)
    }
  }

  /// Signs in without downloading anything. It takes a queue slot like any job, so a batch
  /// that is already signing in is not asked to sign in twice.
  func signIn(
    username: String, executable: URL, root: URL, rememberSession: Bool = true,
    onSignedIn: @escaping @MainActor () -> Void = {}
  ) {
    enqueue(id: Self.signInID, item: nil, username: username, rememberSession: rememberSession) { worker, account in
      worker.signIn(
        username: account, executable: executable, root: root,
        rememberSession: rememberSession, onSignedIn: onSignedIn)
    }
  }

  func cancel(_ job: WorkshopDownload) {
    guard downloads.contains(where: { $0 === job }), job.isPending || job.isPaused else { return }
    job.isPaused = false
    job.wasCancelled = true
    if job.isQueued || !job.occupiesSlot {
      job.isQueued = false
      job.wasCancelled = true
      job.begin = nil
      job.worker.discardCheckpoint()
      startQueuedDownloads()
    } else {
      job.worker.cancel()
    }
    persist()
  }

  func pause(_ job: WorkshopDownload) {
    guard downloads.contains(where: { $0 === job }), job.isPending, !job.isSignIn else { return }
    job.isPaused = true
    if job.isQueued {
      job.isQueued = false
      startQueuedDownloads()
    } else {
      job.worker.pause()
    }
    persist()
  }

  /// A prerequisite request owns this paused job until it can be enqueued again.
  /// Its content checkpoint remains available under the same stable id.
  func transferPausedToRequest(id: String) {
    downloads.removeAll { $0.id == id && $0.isPaused && !$0.isPending }
    persist()
  }

  func discardRetainedCheckpoint(id: String) {
    guard !downloads.contains(where: { $0.id == id && $0.isPending }),
      let checkpoint = checkpointDirectory(for: id) else { return }
    try? WorkshopDownloadCheckpoint.remove(at: checkpoint)
  }

  func clearCompleted() {
    for job in downloads where !job.isPending && !job.isPaused { job.worker.discardCheckpoint() }
    downloads.removeAll { !$0.isPending && !$0.isPaused }
    persist()
  }

  func forgetSavedAccount() {
    guard !isRunning else {
      errorMessage = String(
        localized: "Wait for active and queued downloads to finish before logging out of Steam.")
      return
    }
    do {
      try WorkshopDownloader.removeSession(at: sessionDirectory)
      savedAccount = nil
      errorMessage = nil
    } catch {
      errorMessage = String(localized: "Could not log out of Steam: \(error.localizedDescription)")
    }
  }

  func shutdown() async {
    isShuttingDown = true
    if let wakeObserver { wakeCenter.removeObserver(wakeObserver) }
    wakeObserver = nil
    // Stop every child before awaiting any one. Download bytes survive; sign-in prompts do not.
    for job in downloads where job.isPending {
      if job.isSignIn { cancel(job) } else { pause(job) }
    }
    for job in downloads where job.occupiesSlot { await job.worker.shutdown() }
    persist()
  }

  private func enqueue(
    id: String, item: WorkshopItem?, username: String, rememberSession: Bool,
    begin: @escaping (WorkshopDownloader, String) -> Void
  ) {
    guard !isShuttingDown, downloads.first(where: { $0.id == id })?.isPending != true else { return }
    guard let account = WorkshopDownloader.normalizedAccount(username) else {
      errorMessage =
        String(localized: "Enter your Steam account login name (not your display name). An account that owns Wallpaper Engine is required.")
      return
    }
    if let current = rememberSessionWhileRunning, current != rememberSession {
      errorMessage =
        String(localized: "Wait for active and queued downloads to finish before changing saved sign-in settings.")
      return
    }
    if !rememberSession && !isRunning {
      forgetSavedAccount()
      guard errorMessage == nil else { return }
    }
    errorMessage = nil
    let job = WorkshopDownload(
      id: id, item: item, account: account, rememberSession: rememberSession,
      sessionDirectory: sessionDirectory, runtimeProvider: runtimeProvider,
      checkpointDirectory: checkpointDirectory(for: id), networkMonitor: networkMonitorFactory?())
    job.begin = { [weak job] in
      guard let job else { return }
      begin(job.worker, account)
    }
    job.worker.onAuthenticated = { [weak self] in
      guard let self else { return }
      // The worker saved the accepted sign-in before calling; siblings can restore it now.
      self.savedAccount = WorkshopDownloader.readSavedAccount(at: self.sessionDirectory)
      self.startQueuedDownloads()
    }
    job.worker.onFinished = { [weak self, weak job] in
      guard let self, let job else { return }
      job.occupiesSlot = false
      self.savedAccount = WorkshopDownloader.readSavedAccount(at: self.sessionDirectory)
      if job.worker.completedSuccessfully {
        job.isPaused = false
        job.wasCancelled = false
      }
      self.settleSessionConflict(for: job)
      if !job.isQueued && !job.isPaused { job.begin = nil }
      self.persist()
      self.startQueuedDownloads()
    }
    let previous = downloads
    if let index = downloads.firstIndex(where: { $0.id == job.id }) { downloads[index] = job }
    else { downloads.append(job) }
    guard persist() else {
      downloads = previous
      return
    }
    startQueuedDownloads()
  }

  /// Steam ended this job's session for another sign-in with the same account. When that other
  /// sign-in was one of our own sessions, the account cannot run two at once: the queue turns
  /// serial and the ended job goes back in line once, behind whatever is still running.
  private func settleSessionConflict(for job: WorkshopDownload) {
    guard job.worker.endedBySessionConflict, !job.isCancelled, !job.isPaused, !isShuttingDown else { return }
    let sibling = downloads.contains { $0 !== job && $0.occupiesSlot && $0.account == job.account }
    guard sibling else {
      AppLog.warn("Steam ended the download session for \(job.id): the account signed in elsewhere")
      return
    }
    if !sessionConflictDetected {
      AppLog.warn(
        "Steam ended the session of download \(job.id) for another of our sessions; Workshop downloads now run one at a time")
    }
    sessionConflictDetected = true
    guard !job.retriesAfterSessionConflict, job.begin != nil else { return }
    job.retriesAfterSessionConflict = true
    job.isQueued = true
    job.hold = .previous
  }

  /// Fills free slots in queue order. The queue holds, in order, rather than skipping a job.
  private func startQueuedDownloads() {
    guard !isShuttingDown else { return }
    for job in downloads where job.isQueued && !job.isPaused {
      if let reason = activeCount < slotLimit ? holdBehindRunningJobs(job) : .slot {
        hold(reason, from: job)
        return
      }
      job.isQueued = false
      job.occupiesSlot = true
      AppLog.info("Starting Workshop download \(job.id) (\(activeCount) of \(slotLimit) slots in use)")
      job.begin?()
      persist()
      if !job.worker.isRunning {
        // Invalid input can fail synchronously without starting a task.
        job.occupiesSlot = false
        job.begin = nil
      }
    }
  }

  /// Nothing holds a job while no slot is taken. Otherwise the running jobs decide: a prompt on
  /// screen must be answered first (prompts never pile up), sessions that cannot share a sign-in
  /// go one by one, and with a saved sign-in for the account on disk a job starts right away —
  /// it restores that sign-in itself and does not wait for the first job to get through Steam's
  /// login. Only a job that has no sign-in to restore waits for the running one to be accepted
  /// and saved.
  private func holdBehindRunningJobs(_ job: WorkshopDownload) -> WorkshopDownload.Hold? {
    let running = downloads.filter { $0.occupiesSlot }
    guard !running.isEmpty else { return nil }
    if running.contains(where: { $0.worker.prompt != nil || $0.worker.steamGuardChallenge != nil }) {
      return .signIn
    }
    if !job.rememberSession || sessionConflictDetected { return .previous }
    if savedAccount == job.account { return nil }
    return running.contains(where: { $0.worker.isAuthenticating }) ? .signIn : nil
  }

  /// The queue waits as a whole, so every job from the held one on shows the same reason.
  private func hold(_ reason: WorkshopDownload.Hold, from first: WorkshopDownload) {
    var reached = false
    for job in downloads where job.isQueued {
      reached = reached || job === first
      guard reached, job.hold != reason else { continue }
      job.hold = reason
      if job === first { AppLog.info("Workshop download \(job.id) waits: \(job.status)") }
    }
  }
}
