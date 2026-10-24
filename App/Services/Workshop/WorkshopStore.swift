import Foundation
import Observation

struct WorkshopQuery: Equatable, Sendable {
  let text: String
  let kind: WorkshopKind
  let sort: WorkshopSort
  /// Steam `requiredtags[]`: every one must be on an item.
  var tags: [String] = []
  /// Steam `excludedtags[]`: an item carrying any of them is dropped.
  var excludedTags: [String] = []
  /// Where the tiles come from; only the browse and collections lists read `text` and `sort`.
  var source: WorkshopSource = .browse

  /// The Workshop item a pasted link or id names. Only the wallpapers list takes it: the
  /// other sources read `text` as words to search for.
  var itemID: String? { source == .browse ? WorkshopLink.itemID(in: text) : nil }
}

struct WorkshopRequest: Equatable, Sendable {
  let query: WorkshopQuery
  let page: Int
}

/// Prerequisites are resolved in this order; a request reports the first one it still needs.
enum WorkshopDownloadStage: String, Sendable {
  case setup, account, resources, ready
}

/// A retained download intent. One click keeps the wallpaper the user asked for while
/// the runtime, the Steam account, and shared scene assets are resolved in turn.
struct WorkshopDownloadRequest: Identifiable, Codable, Sendable {
  /// Workshop item id, `WorkshopStore.sceneAssetsRequestID` for the shared assets download, or
  /// `WorkshopStore.signInRequestID` for a sign-in that downloads nothing.
  let id: String
  let item: WorkshopItem?
  var account: String
  var rememberSession: Bool
  /// Explicit consent to download Wallpaper Engine's multi-gigabyte shared assets.
  var includesResources: Bool
  /// The downloader rejected these inputs; only a fresh continuation may retry them, so
  /// automatic resumption cannot spin on the same rejected account.
  var refused = false
  /// Restored requests wait for an explicit continuation after relaunch.
  var isPaused = false
}

/// The choice behind **Download and apply**: apply the wallpaper to this display once it has
/// arrived, if the user has not chosen anything else for that display in the meantime. It lives
/// in memory only, so a relaunch never applies anything the user did not see arrive.
struct ApplyOnArrival: Equatable, Sendable {
  let displayID: String
  /// The display's count of the user's own choices when the click was made, the click included;
  /// any later choice of theirs for that display, another click on **Download and apply**
  /// among them, changes it and withdraws this one.
  let userRevision: UInt64
  let created: Date
  /// The files are installed and only the shared scene assets they need are still downloading.
  var awaitsAssets = false
}

@MainActor
@Observable
final class WorkshopStore {
  var searchText = ""
  var kind: WorkshopKind = .all
  var sort: WorkshopSort = .trendingYear
  var tags: [String] = []
  var excludedTags: [String] = WorkshopStore.defaultExcludedTags
  /// Wallpaper Engine's own defaults: the sidebar lists every Type, Age rating, Resolution and
  /// Genre tag as a checkbox and unchecking one excludes it. Out of the box only Everyone is
  /// rated in, genre-less items are hidden, and Application / Asset are never offered.
  static let defaultExcludedTags = ["Application", "Asset", "Questionable", "Mature", "Unspecified"]
  var selectedItem: WorkshopItem?
  /// Where the next search looks. Opening an author or a collection remembers the source it
  /// was opened from, so Back returns to it.
  var source: WorkshopSource = .browse
  private(set) var sourceHistory: [WorkshopSource] = []
  /// The shown source's own name when it has one Steam gave, such as an author's.
  private(set) var sourceTitle: String?
  /// The Steam Community session subscriptions are read with. `webSessions` keeps it between
  /// launches; it ends on Sign Out, or when Steam refuses to renew it.
  private(set) var steamWebSession: SteamWebSession?
  /// Where the session is kept between launches; nil keeps it in memory only.
  @ObservationIgnored private let webSessions: (any SteamWebSessionStoring)?
  @ObservationIgnored private var webSessionRestore: Task<Void, Never>?
  /// The renewal in flight, which every reader of an expired session waits for.
  @ObservationIgnored private var webSessionRenewal: Task<SteamWebSession, Error>?
  private(set) var isSigningInToSteamWeb = false
  private(set) var sceneAssetsReady: Bool
  /// Where scene wallpapers read the shared assets from. Finding it probes up to four
  /// folders, so it is found with the readiness, not for every page snapshot.
  private(set) var sceneAssetsURL: URL
  @ObservationIgnored private let sceneAssetsLocation: @MainActor () -> URL
  @ObservationIgnored private let sceneAssetsAvailable: @MainActor (URL) -> Bool

  /// Runs whenever the panel comes forward, so an assignment that changes nothing is
  /// skipped: every assignment would wake this store's observers.
  func refreshSceneAssetsReadiness() {
    let url = sceneAssetsLocation()
    let ready = sceneAssetsAvailable(url)
    if url != sceneAssetsURL { sceneAssetsURL = url }
    if ready != sceneAssetsReady { sceneAssetsReady = ready }
  }
  private(set) var items: [WorkshopItem] = []
  private(set) var page = 1
  private(set) var totalPages = 1
  private(set) var totalCount = 0
  /// Results Steam can actually serve for the committed query: its result count capped by
  /// its 1,000 pages of 30, so the last page never asks for an unreachable item.
  private(set) var reachableCount = 0
  /// A panel page is one Steam page: 30 tiles, and never more than 1,000 pages. The grid lays
  /// those tiles out in as many columns as its width holds and scrolls the rest, so a window
  /// resize only reflows the tiles and never changes what a page holds. Collections screened
  /// for a hidden age rating are the exception: see `filledPage`.
  static let pageSize = WorkshopService.pageSize
  static let maxPages = WorkshopService.maxPages
  private(set) var isLoading = false
  private(set) var hasLoaded = false
  /// The list on show was found from the links on a Steam page this app could no longer read
  /// the usual way, so it may be incomplete and its page count is an estimate.
  private(set) var isDegraded = false
  var errorMessage: String?
  let downloader: WorkshopDownloadManager
  let steamCMDSetup: SteamCMDSetupStore
  /// Which installed Workshop wallpapers have updates; an update downloads like any item.
  let updates: WorkshopUpdateStore
  @ObservationIgnored private let service: WorkshopService
  @ObservationIgnored private let defaults: UserDefaults
  static let concurrentDownloadsKey = "WallpaperMachine.concurrentDownloads"
  var username = ""
  var selectedDownloadID: String?
  var showsDownloadDetails = false
  private(set) var downloadRequests: [WorkshopDownloadRequest] = []
  private(set) var downloadPersistenceError: String?
  /// Wallpapers whose download was started with **Download and apply**, by item id. Never
  /// written to disk: a relaunch restores jobs paused and unapplied.
  private(set) var applyIntents: [String: ApplyOnArrival] = [:]
  /// Why a wallpaper that arrived was not applied after all, by item id, in words for the
  /// person. Kept until the item is requested again or the finished downloads are cleared.
  private(set) var applyNotes: [String: String] = [:]
  /// How long a click on **Download and apply** stays good. A download that takes longer than
  /// this has outlived whatever the person had in mind.
  static let applyIntentLifetime: TimeInterval = 3600
  @ObservationIgnored private let now: @MainActor () -> Date
  @ObservationIgnored private var applyTasks: [String: Task<Void, Never>] = [:]
  @ObservationIgnored private let requestFile: URL
  @ObservationIgnored private weak var downloadBridge: BridgeStore?
  @ObservationIgnored private var observingDownloads = false

  static let sceneAssetsRequestID = "scene-assets"
  static let signInRequestID = WorkshopDownloadManager.signInID

  var hasDownloadActivity: Bool { !downloader.downloads.isEmpty || !downloadRequests.isEmpty }
  var selectedDownload: WorkshopDownload? {
    downloader.downloads.first { $0.id == selectedDownloadID }
      ?? downloader.downloads.first { $0.isPending }
      ?? downloader.downloads.last
  }

  /// A finished wallpaper download stays valid even when the shared assets job fails, so the
  /// missing scene readiness needs its own standing warning instead of a transient job error.
  var sceneAssetsFailure: String? {
    guard !sceneAssetsReady, let job = downloader.download(for: nil), !job.isPending else {
      return nil
    }
    if job.isCancelled {
      return String(
        localized: "Shared scene assets were not installed, so scene wallpapers cannot play yet.")
    }
    return job.worker.errorMessage.map {
      String(
        localized:
          "Shared scene assets are still missing, so scene wallpapers cannot play yet: \($0)")
    }
  }

  convenience init(service: WorkshopService = WorkshopService()) {
    self.init(
      service: service, downloader: WorkshopDownloadManager(), storageDirectory: ClientPaths.storageURL,
      webSessions: KeychainSteamWebSessionStore())
  }

  /// `storageDirectory` holds the partial downloads, beside the library (`ClientPaths.storageURL`);
  /// nil keeps them in `supportDirectory`, as a test's single temporary folder wants.
  init(
    service: WorkshopService = WorkshopService(), downloader: WorkshopDownloadManager,
    supportDirectory: URL = ClientPaths.supportURL, storageDirectory: URL? = nil,
    defaults: UserDefaults = ClientPreferences.defaults,
    runtimeProvider: any SteamCMDRuntimeProviding = SteamCMDRuntimeService(),
    updates: WorkshopUpdateStore? = nil,
    sceneAssetsLocation: @escaping @MainActor () -> URL = { ClientPaths.assetsURL },
    sceneAssetsAvailable: @escaping @MainActor (URL) -> Bool = { ClientPaths.hasSceneAssets(at: $0) },
    webSessions: (any SteamWebSessionStoring)? = nil,
    now: @escaping @MainActor () -> Date = Date.init
  ) {
    self.service = service
    self.webSessions = webSessions
    self.now = now
    requestFile = supportDirectory.appendingPathComponent("Downloads/workshop-requests.json")
    self.downloader = downloader
    self.updates = updates ?? WorkshopUpdateStore(defaults: defaults)
    self.defaults = defaults
    self.sceneAssetsLocation = sceneAssetsLocation
    self.sceneAssetsAvailable = sceneAssetsAvailable
    let assetsURL = sceneAssetsLocation()
    sceneAssetsURL = assetsURL
    sceneAssetsReady = sceneAssetsAvailable(assetsURL)
    if let saved = defaults.object(forKey: Self.concurrentDownloadsKey) as? Int {
      downloader.setMaximumConcurrentDownloads(saved)
    }
    self.steamCMDSetup = SteamCMDSetupStore(
      downloader: downloader, supportDirectory: supportDirectory,
      defaults: defaults, runtimeProvider: runtimeProvider)
    downloader.configurePersistence(at: ClientPaths.workshopDownloadsURL(in: storageDirectory ?? supportDirectory))
    if let data = try? Data(contentsOf: requestFile),
      let saved = try? JSONDecoder().decode([WorkshopDownloadRequest].self, from: data)
    {
      downloadRequests = saved.filter { $0.id != Self.signInRequestID }.map {
        var request = $0
        request.isPaused = true
        return request
      }
      // A crash between queue handoff writes may leave both records; the retained request wins.
      for request in downloadRequests { downloader.transferPausedToRequest(id: request.id) }
    }
  }

  func showDownload(_ job: WorkshopDownload) {
    guard downloader.downloads.contains(where: { $0 === job }) else { return }
    selectedDownloadID = job.id
    showsDownloadDetails = true
  }

  /// How many Workshop downloads may run at once; kept across launches.
  func setConcurrentDownloads(_ count: Int) {
    downloader.setMaximumConcurrentDownloads(count)
    defaults.set(downloader.maximumConcurrentDownloads, forKey: Self.concurrentDownloadsKey)
  }

  /// The entry point for a single click: start immediately when every prerequisite is met,
  /// otherwise retain the intent and report which prerequisite it is waiting on.
  ///
  /// With `displayID` the wallpaper is applied to that display once it has arrived, unless the
  /// person chooses something else for the display first ([ApplyOnArrival]). Only a wallpaper
  /// that can be applied there gets that: an Application or a collection, or a display that is
  /// gone, disabled or mirroring, is downloaded like any other item.
  func requestDownload(
    item: WorkshopItem?, rememberSession: Bool, bridge: BridgeStore, applyTo displayID: String? = nil
  ) {
    startDownloadLifecycle(bridge: bridge)
    let id = item?.id ?? Self.sceneAssetsRequestID
    if let job = downloader.download(for: item?.id), job.isPending {
      showDownload(job)
      return
    }
    let existing = downloadRequests.first { $0.id == id }
    if let item, let displayID, canApply(item, to: displayID, bridge: bridge) {
      // Asking is choosing for the display, and the latest ask wins: an earlier Download and
      // apply for it is withdrawn, whichever of the two arrives first, and no two asks share a
      // revision for the first apply to arrive to move out from under the other.
      let slot = BridgeStore.activationSlot(displayId: displayID)
      bridge.commands.noteUserChoice(in: [slot])
      applyIntents[id] = ApplyOnArrival(
        displayID: displayID, userRevision: bridge.commands.userRevision(for: slot), created: now())
      if applyNotes[id] != nil { applyNotes[id] = nil }
    } else if existing == nil {
      // A plain download asks for no apply, whatever an earlier attempt asked. A request that
      // is retained keeps the choice it was made with.
      dropApplyChoice(id)
    }
    let retained = existing?.account ?? ""
    resolve(
      WorkshopDownloadRequest(
        id: id, item: item ?? existing?.item,
        account: retained.isEmpty ? suggestedAccount : retained,
        // A retained request keeps the choice it was continued with.
        rememberSession: existing?.rememberSession ?? rememberSession,
        includesResources: existing?.includesResources ?? false),
      bridge: bridge)
  }

  /// Downloads an installed Workshop wallpaper again, to repair a damaged copy or take the
  /// Workshop's current one. It is the update path: the item is asked of Steam, so what is
  /// downloaded is what Steam serves now, and the new folder replaces the installed one only once
  /// it has arrived whole, so a failed download leaves the installed copy as it was. Everything
  /// after the lookup (SteamCMD, account, consent, progress) is an ordinary download.
  ///
  /// Nothing happens when a download or a retained request for the item already exists: that is
  /// where the user continues it.
  func requestReinstall(id: String, rememberSession: Bool, bridge: BridgeStore) async throws {
    guard WallpaperImportService.workshopID(id) != nil else {
      throw WallpaperActionError(message: String(localized: "Choose a valid numeric Workshop item identifier."))
    }
    if let job = downloader.download(for: id), job.isPending {
      showDownload(job)
      return
    }
    guard !downloadRequests.contains(where: { $0.id == id }) else { return }
    let item = try await service.details(ids: [id]).first { $0.id == id && $0.collectionSize == nil }
    guard let item else {
      throw WallpaperActionError(
        message: String(localized: "Steam no longer serves this wallpaper, so it can’t be reinstalled."))
    }
    guard item.kind != .application else {
      throw WallpaperActionError(
        message: String(
          localized:
            "Choose a valid Workshop wallpaper. Application wallpapers execute Windows programs and cannot be used on macOS."))
    }
    requestDownload(item: item, rememberSession: rememberSession, bridge: bridge)
  }

  /// Signs in to Steam without downloading anything, so the account and its saved sign-in are in
  /// place before the first download. Rides the same ladder as a download: SteamCMD must be set
  /// up first, and a running sign-in is shown rather than started twice.
  func requestSignIn(account: String, rememberSession: Bool, bridge: BridgeStore) {
    startDownloadLifecycle(bridge: bridge)
    if let job = downloader.signIn, job.isPending {
      showDownload(job)
      return
    }
    username = account
    resolve(
      WorkshopDownloadRequest(
        id: Self.signInRequestID, item: nil, account: account,
        rememberSession: rememberSession, includesResources: true),
      bridge: bridge)
  }

  /// Supplies the account and the consent a retained request is waiting on, then resumes it.
  /// Returns `false` when the id names neither a retained request nor a known Workshop item.
  @discardableResult
  func continueDownload(
    id: String, account: String, rememberSession: Bool,
    includeResources: Bool, bridge: BridgeStore
  ) -> Bool {
    startDownloadLifecycle(bridge: bridge)
    let existing = downloadRequests.first { $0.id == id }
    let itemless = id == Self.sceneAssetsRequestID || id == Self.signInRequestID
    let item = itemless ? nil : existing?.item ?? workshopItem(id: id)
    guard itemless || item != nil else { return false }
    username = account
    resolve(
      WorkshopDownloadRequest(
        id: id, item: item, account: account,
        rememberSession: rememberSession,
        includesResources: existing?.includesResources == true || includeResources),
      bridge: bridge)
    return true
  }

  func removeDownloadRequest(id: String) {
    guard downloadRequests.contains(where: { $0.id == id }) else { return }
    dropApplyChoice(id)
    downloadRequests.removeAll { $0.id == id }
    downloader.discardRetainedCheckpoint(id: id)
    persistDownloadRequests()
  }

  func cancelDownload(id: String) {
    dropApplyChoice(id)
    removeDownloadRequest(id: id)
    if let job = downloader.downloads.first(where: { $0.id == id }) { downloader.cancel(job) }
  }

  /// "Change account" stops exactly this job and keeps its wallpaper as an intent with no
  /// account, so nothing signs in again under the name the user rejected. Consent already
  /// given for shared assets is preserved; other queued jobs are untouched.
  func changeDownloadAccount(id: String) async {
    guard let job = downloader.downloads.first(where: { $0.id == id }) else { return }
    let item = job.item
    let rememberSession = downloader.rememberSessionWhileRunning ?? true
    downloader.cancel(job)
    await job.worker.shutdown()
    // The rejected name must not survive as the suggestion for this or any new intent.
    if Self.normalizedAccount(username) == Self.normalizedAccount(job.account) { username = "" }
    upsert(
      WorkshopDownloadRequest(
        id: id, item: item, account: "",
        rememberSession: rememberSession, includesResources: true,
        refused: true))
  }

  /// The app owns this observation for its whole lifetime, including while the panel is closed.
  func startDownloadLifecycle(bridge: BridgeStore) {
    downloadBridge = bridge
    guard !observingDownloads else { return }
    observingDownloads = true
    observeDownloadPrerequisites()
  }

  private func observeDownloadPrerequisites() {
    withObservationTracking {
      _ = steamCMDSetup.isBusy
      _ = steamCMDSetup.selectedRuntime
      _ = sceneAssetsReady
      _ = username
      _ = downloader.savedAccount
      _ = downloader.isRunning
      _ = downloadRequests
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        guard let self, let bridge = self.downloadBridge else { return }
        self.resumeDownloadRequests(bridge: bridge)
        self.settleApplyIntentsAwaitingAssets(bridge: bridge)
        self.observeDownloadPrerequisites()
      }
    }
  }

  /// Prerequisites can complete with no panel attached.
  func resumeDownloadRequests(bridge: BridgeStore) {
    for request in downloadRequests where !request.isPaused {
      var request = request
      let suggestion = suggestedAccount
      // A rejected account must not be refilled from the saved or typed suggestion.
      if !request.refused, request.account.isEmpty, !suggestion.isEmpty {
        request.account = suggestion
        upsert(request)
      }
      if stage(for: request) == .ready { resolve(request, bridge: bridge) }
    }
  }

  func stage(for request: WorkshopDownloadRequest) -> WorkshopDownloadStage {
    if steamCMDSetup.isBusy || steamCMDSetup.selectedRuntime == nil { return .setup }
    if request.refused || Self.normalizedAccount(request.account).isEmpty { return .account }
    // A sign-in downloads nothing, so shared resources never come into it.
    if request.id == Self.signInRequestID { return .ready }
    if !request.includesResources, needsResources(request) { return .resources }
    return .ready
  }

  /// Resolves an item id against browsing results, the retained selection, retained requests,
  /// and running jobs, so an intent survives searching and paging away from the item.
  func workshopItem(id: String) -> WorkshopItem? {
    if let item = items.first(where: { $0.id == id }) { return item }
    if let selectedItem, selectedItem.id == id { return selectedItem }
    if let item = downloadRequests.first(where: { $0.id == id })?.item { return item }
    if let item = downloader.downloads.first(where: { $0.item?.id == id })?.item { return item }
    return updates.available[id]
  }

  /// A running session pins the account every queued job reuses; a name typed elsewhere must
  /// not seed an intent that would sign in as somebody else.
  var suggestedAccount: String {
    if let active = downloader.downloads.last(where: { $0.isPending })?.account { return active }
    let typed = username.trimmingCharacters(in: .whitespacesAndNewlines)
    return typed.isEmpty ? downloader.savedAccount ?? "" : typed
  }

  private var sharedAssetsPending: Bool { downloader.download(for: nil)?.isPending == true }

  /// Downloading Wallpaper Engine's shared assets is always an explicit choice, even when a
  /// copy is already installed. A scene only needs that consent while the assets are missing
  /// and no shared job is already running for it to ride.
  private func needsResources(_ request: WorkshopDownloadRequest) -> Bool {
    guard let item = request.item else { return true }
    return item.kind == .scene && !sceneAssetsReady && !sharedAssetsPending
  }

  private func needsSharedAssets(_ item: WorkshopItem) -> Bool {
    item.kind == .scene && !sceneAssetsReady
  }

  @discardableResult
  private func persistDownloadRequests() -> Bool {
    do {
      let requests = downloadRequests.filter { $0.id != Self.signInRequestID }
      try FileManager.default.createDirectory(at: requestFile.deletingLastPathComponent(), withIntermediateDirectories: true)
      try JSONEncoder().encode(requests).write(to: requestFile, options: .atomic)
      downloadPersistenceError = nil
      return true
    } catch {
      downloadPersistenceError = String(localized: "Could not save the download queue: \(error.localizedDescription)")
      AppLog.warn("Could not save pending Workshop downloads: \(error.localizedDescription)")
      return false
    }
  }

  @discardableResult
  func resumeDownloadRequest(id: String, bridge: BridgeStore) -> Bool {
    guard var request = downloadRequests.first(where: { $0.id == id && $0.isPaused }) else { return false }
    request.isPaused = false
    resolve(request, bridge: bridge)
    return true
  }

  func resumeDownload(_ job: WorkshopDownload, bridge: BridgeStore) {
    guard job.isPaused, !job.isPending else { return }
    // Resuming does not authorize a separate shared-assets download.
    _ = continueDownload(id: job.id, account: job.account, rememberSession: job.rememberSession,
                         includeResources: false, bridge: bridge)
  }

  @discardableResult
  private func upsert(_ request: WorkshopDownloadRequest) -> Bool {
    if let index = downloadRequests.firstIndex(where: { $0.id == request.id }) {
      downloadRequests[index] = request
    } else {
      downloadRequests.append(request)
    }
    return persistDownloadRequests()
  }

  private func resolve(_ request: WorkshopDownloadRequest, bridge: BridgeStore) {
    guard stage(for: request) == .ready, let runtime = steamCMDSetup.selectedRuntime else {
      let previous = downloadRequests
      if upsert(request) {
        downloader.transferPausedToRequest(id: request.id)
      } else if downloader.downloads.contains(where: { $0.id == request.id && $0.isPaused }) {
        // Keep the durable paused owner when its replacement request could not be saved.
        downloadRequests = previous
      }
      return
    }
    if request.id == Self.signInRequestID {
      downloader.signIn(
        username: request.account, executable: runtime.executableURL,
        // A sign-in fetches nothing, so it stays beside the saved sign-in, not the library.
        root: ClientPaths.supportURL,
        rememberSession: request.rememberSession)
    } else if let item = request.item {
      // Shared assets are queued first and only once: other scenes ride the same job.
      if needsSharedAssets(item), !sharedAssetsPending {
        installAssets(request, runtime: runtime)
      }
      // A wallpaper already in the library is being updated: its new files replace the old,
      // and a display showing it loads them again.
      let replacing = bridge.librarySnapshot.wallpapers.contains { $0.id == item.id }
      downloader.start(
        item: item, username: request.account, executable: runtime.executableURL,
        library: ClientPaths.libraryURL, rememberSession: request.rememberSession
      ) { [weak self] in
        try await self?.finishInstall(item: item, replacing: replacing, bridge: bridge)
      }
    } else {
      installAssets(request, runtime: runtime)
    }
    let started = request.id == Self.signInRequestID ? downloader.signIn : downloader.download(for: request.item?.id)
    if let job = started, job.isPending {
      // Persist the started job before deleting its retained intent so a crash cannot lose both.
      downloadRequests.removeAll { $0.id == request.id }
      persistDownloadRequests()
      selectedDownloadID = job.id
    } else if downloader.errorMessage != nil {
      // The downloader refused the inputs; keep the intent so the user can correct them.
      var refused = request
      refused.refused = true
      upsert(refused)
    }
  }

  private func installAssets(_ request: WorkshopDownloadRequest, runtime: SteamCMDRuntime) {
    let destination = ClientPaths.managedAssetsURL
    downloader.installAssets(
      username: request.account, executable: runtime.executableURL,
      destination: destination, rememberSession: request.rememberSession
    ) {
      try ClientPaths.configureAssetsFolder(at: destination)
      self.refreshSceneAssetsReadiness()
      if let bridge = self.downloadBridge { self.settleApplyIntentsAwaitingAssets(bridge: bridge) }
    }
  }

  /// What follows a Workshop item arriving in the library: record it, rescan, load a replaced
  /// wallpaper's new files on the displays showing it, and apply it if that is what was asked.
  func finishInstall(item: WorkshopItem, replacing: Bool, bridge: BridgeStore) async throws {
    // The files are already in the library, so the install counts even if the refresh fails.
    updates.recordInstalled(item.id)
    if !replacing { bridge.supportPrompt?.recordDownload(wallpaperID: item.id) }
    do {
      try await bridge.refreshLibraryAsync()
    } catch {
      // The download reports that the library did not refresh, and what is not in the library
      // cannot be applied.
      applyIntents[item.id] = nil
      throw error
    }
    if replacing {
      do {
        try await bridge.reloadWallpaperAsync(id: item.id)
      } catch {
        AppLog.warn("Workshop item \(item.id) was updated but could not be reloaded: \(error.localizedDescription)")
      }
    }
    scheduleApplyOnArrival(item, bridge: bridge)
  }

  private func canApply(_ item: WorkshopItem, to displayID: String, bridge: BridgeStore) -> Bool {
    guard item.kind != .application, item.collectionSize == nil else { return false }
    return (try? bridge.validateActivationTarget(displayID)) != nil
  }

  private func dropApplyChoice(_ id: String) {
    if applyIntents[id] != nil { applyIntents[id] = nil }
    if applyNotes[id] != nil { applyNotes[id] = nil }
  }

  /// Whether `id` is to be applied when its download finishes, for the panel to say so.
  func appliesOnArrival(_ id: String) -> Bool { applyIntents[id] != nil }

  /// The apply in flight for `id`, which a test awaits instead of sleeping.
  func applyInFlight(_ id: String) -> Task<Void, Never>? { applyTasks[id] }

  /// A scene needs Wallpaper Engine's shared assets to play: when they are still downloading
  /// the apply waits for them, and otherwise it goes ahead and says why it cannot.
  private func scheduleApplyOnArrival(_ item: WorkshopItem, bridge: BridgeStore) {
    guard var intent = applyIntents[item.id] else { return }
    if item.kind == .scene {
      refreshSceneAssetsReadiness()
      if !sceneAssetsReady, sharedAssetsPending {
        intent.awaitsAssets = true
        applyIntents[item.id] = intent
        return
      }
    }
    startApply(item.id, bridge: bridge)
  }

  /// Settles the applies that were waiting for the shared scene assets: they go ahead once the
  /// assets are there, and are withdrawn, with a note, when the job that was to install them
  /// is over without having done so.
  func settleApplyIntentsAwaitingAssets(bridge: BridgeStore) {
    for (id, intent) in applyIntents where intent.awaitsAssets {
      if sceneAssetsReady {
        var released = intent
        released.awaitsAssets = false
        applyIntents[id] = released
        startApply(id, bridge: bridge)
      } else if !sharedAssetsPending {
        applyIntents[id] = nil
        let reason = sceneAssetsFailure
          ?? String(localized: "Shared scene assets were not installed, so scene wallpapers cannot play yet.")
        applyNotes[id] = String(localized: "Downloaded, but it could not be applied: \(reason)")
      }
    }
  }

  /// Applies from a task of its own, so a slow activation never holds a download slot.
  private func startApply(_ id: String, bridge: BridgeStore) {
    applyTasks[id] = Task { @MainActor [weak self] in
      await self?.applyOnArrival(id, bridge: bridge)
      self?.applyTasks[id] = nil
    }
  }

  /// Applies `id` as the person's own choice, unless they have chosen something else for the
  /// display since they asked. The choice is checked in the same step that joins the display's
  /// command line, so nothing can slip in between the two.
  private func applyOnArrival(_ id: String, bridge: BridgeStore) async {
    guard let intent = applyIntents.removeValue(forKey: id) else { return }
    let slot = BridgeStore.activationSlot(displayId: intent.displayID)
    guard bridge.commands.userRevision(for: slot) == intent.userRevision else {
      applyNotes[id] = Self.choseAnotherNote
      return
    }
    guard now().timeIntervalSince(intent.created) <= Self.applyIntentLifetime else {
      applyNotes[id] = String(localized: "Downloaded, but not applied because the download took more than an hour.")
      return
    }
    do {
      try bridge.validateActivationTarget(intent.displayID)
      let ran = try await bridge.commands.run(slot: slot, subject: id) {
        try await bridge.activateWallpaperAsync(id: id, displayId: intent.displayID, origin: .user)
      }
      // A newer choice of theirs took the display's turn while this one waited.
      if !ran { applyNotes[id] = Self.choseAnotherNote }
    } catch {
      applyNotes[id] = String(localized: "Downloaded, but it could not be applied: \(error.localizedDescription)")
    }
  }

  private static var choseAnotherNote: String {
    String(localized: "Downloaded, but not applied because you chose another wallpaper.")
  }

  func clearDownloadActivity() {
    downloader.clearCompleted()
    if !applyNotes.isEmpty { applyNotes = [:] }
    if !downloader.downloads.contains(where: { $0.id == selectedDownloadID }) {
      selectedDownloadID = nil
    }
    if !hasDownloadActivity { showsDownloadDetails = false }
  }

  static func normalizedAccount(_ account: String) -> String {
    account.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }
  @ObservationIgnored private var searchTask: Task<Void, Never>?
  @ObservationIgnored private var generation = UUID()
  private(set) var committedQuery: WorkshopQuery?
  private(set) var failedRequest: WorkshopRequest?
  /// Panel pages fetched for `cacheQuery`, keyed by page number, plus fetches still in
  /// flight, so paging back never touches the network. A search always starts a fresh
  /// cache, even for the same query.
  @ObservationIgnored private var cacheQuery: WorkshopQuery?
  @ObservationIgnored private var cacheID = UUID()
  @ObservationIgnored private var steamPages: [Int: WorkshopPage] = [:]
  @ObservationIgnored private var steamFetches: [Int: Task<WorkshopPage, Error>] = [:]
  /// For panel pages filled from several Steam pages: the screened Steam pages, keyed by
  /// Steam's page number, with their fetches in flight, and where each panel page starts.
  @ObservationIgnored private var screenedPages: [Int: WorkshopPage] = [:]
  @ObservationIgnored private var screenedFetches: [Int: Task<WorkshopPage, Error>] = [:]
  @ObservationIgnored private var pageStarts: [Int: SteamPosition] = [1: .start]
  /// How many collections each filled panel page showed, for the count once the last is reached.
  @ObservationIgnored private var pageCounts: [Int: Int] = [:]
  /// How many Steam pages a panel page may read before it is shown with what it found, so a
  /// search whose collections are nearly all screened out does not read Steam to its end.
  static let maxSteamPagesPerPage = 10
  /// Fetches the page after the one on show in the background, so paging forward is served
  /// from the cache like paging back. Off unless the owner opts in.
  @ObservationIgnored var prefetchesNextPage = false
  /// Told the preview URLs of every Steam page as it arrives, shown or prefetched, so the
  /// owner of the preview cache can start on them before the panel asks.
  @ObservationIgnored var onPreviewsAvailable: (@MainActor ([URL]) -> Void)?

  private var draftQuery: WorkshopQuery {
    WorkshopQuery(
      text: searchText.trimmingCharacters(in: .whitespacesAndNewlines), kind: kind, sort: sort,
      tags: tags, excludedTags: excludedTags, source: source)
  }

  /// The Steam page showing the current page's tiles.
  var browseURL: URL {
    let query = committedQuery ?? draftQuery
    switch query.source {
    case .browse, .collections:
      if let id = query.itemID { return WorkshopItem.pageURL(id: id) }
      let steamPage = Self.fillsPages(query) ? pageStarts[page]?.page ?? page : page
      return WorkshopService.browseURL(
        search: query.text, kind: query.source == .browse ? query.kind : .all, sort: query.sort,
        page: steamPage, tags: query.tags, excludedTags: query.excludedTags,
        section: query.source == .browse ? "readytouseitems" : "collections")
    case .collection(let id, _):
      return WorkshopItem.pageURL(id: id)
    case .creator(let id, _):
      return WorkshopService.profileURL(steamID: id, subscriptions: false, page: page)
    case .subscriptions:
      return steamWebSession.map { WorkshopService.profileURL(steamID: $0.steamID, subscriptions: true, page: page) }
        ?? URL(string: "https://steamcommunity.com/app/\(WorkshopApp.id)/workshop/")!
    }
  }

  func search() {
    resetCache(for: draftQuery)
    load(WorkshopRequest(query: draftQuery, page: 1))
  }

  /// Shows another source from its first page. An author or a collection is opened from what
  /// is on show, so Back can return there; choosing a list afresh starts a new history.
  func open(_ next: WorkshopSource) {
    switch next {
    case .creator, .collection:
      let current = committedQuery?.source ?? source
      if current != next { sourceHistory.append(current) }
    case .browse, .collections, .subscriptions:
      sourceHistory = []
    }
    source = next
    selectedItem = nil
    search()
  }

  /// Returns to the source the shown one was opened from, from its first page.
  func back() {
    guard let previous = sourceHistory.popLast() else { return }
    source = previous
    selectedItem = nil
    search()
  }

  /// Takes back the session saved by an earlier launch, once; a sign-in that finished first wins.
  /// The keychain is read off the main thread.
  func restoreSteamWebSession() {
    guard let webSessions, webSessionRestore == nil, steamWebSession == nil else { return }
    webSessionRestore = Task { [weak self] in
      let saved = await Task.detached(priority: .userInitiated) { webSessions.load() }.value
      // A sign-out while the keychain answered cancels this, and its session stays forgotten.
      guard let self, !Task.isCancelled, let saved, self.steamWebSession == nil,
        !self.isSigningInToSteamWeb
      else { return }
      self.steamWebSession = saved
      if (self.committedQuery?.source ?? self.source) == .subscriptions { self.search() }
    }
  }

  /// Signs in to Steam Community through Steam's own page, so subscriptions can be read. The
  /// app never sees the password: `obtainCookies` answers the cookies Steam set, or nil when the
  /// window was closed first. The session is saved for later launches; a save that fails (it is
  /// logged) leaves it signed in for this one.
  func signInToSteamWeb(obtainCookies: @MainActor () async -> WebSignInCookies?) async throws {
    guard !isSigningInToSteamWeb else { return }
    isSigningInToSteamWeb = true
    defer { isSigningInToSteamWeb = false }
    guard let cookies = await obtainCookies() else { return }
    guard let session = SteamWebSession(cookie: cookies.session, refresh: cookies.companion) else {
      throw WorkshopFailure(message: String(localized: "Steam’s sign-in finished without a session this app can use. Try signing in again."))
    }
    webSessionRenewal?.cancel()
    webSessionRenewal = nil
    steamWebSession = session
    if (committedQuery?.source ?? source) == .subscriptions { search() }
    persist(session)
  }

  /// Forgets the Steam Community session, here and on this Mac; Steam's own sign-in window keeps
  /// no cookie either.
  func signOutOfSteamWeb() {
    forgetSteamWebSession()
    if (committedQuery?.source ?? source) == .subscriptions {
      cancelSearch()
      clearResults()
    }
  }

  /// Empties the grid, so nothing of an earlier list stays on show in place of one that
  /// cannot be read; the panel then offers what the list needs, such as signing in.
  private func clearResults() {
    items = []
    page = 1
    totalCount = 0
    totalPages = 1
    reachableCount = 0
    committedQuery = nil
    sourceTitle = nil
    hasLoaded = false
    isDegraded = false
  }

  /// The ids of subscribed wallpapers not in `installed`, asking Steam for every page of
  /// subscriptions. Throws `SteamSignInRequired` when the session has ended.
  func missingSubscriptions(installed: Set<String>) async throws -> [WorkshopItem] {
    do {
      guard let session = try await currentSteamWebSession() else { throw SteamSignInRequired() }
      let ids = try await service.subscribedIDs(account: session).filter { !installed.contains($0) }
      return try await service.details(ids: ids).filter { $0.collectionSize == nil }
    } catch is SteamSignInRequired {
      forgetSteamWebSession()
      throw SteamSignInRequired()
    }
  }

  /// The session to read with: the one held, renewed first when its cookie has run out. Readers
  /// that arrive during a renewal wait for that one. Steam refusing the renewal throws
  /// `SteamSignInRequired`; the caller forgets the session.
  func currentSteamWebSession() async throws -> SteamWebSession? {
    if let webSessionRestore, steamWebSession == nil { await webSessionRestore.value }
    guard let session = steamWebSession else { return nil }
    guard session.needsRenewal(at: now()) else { return session }
    let renewal = webSessionRenewal ?? Task { [service] in try await service.renew(session) }
    webSessionRenewal = renewal
    do {
      let renewed = try await renewal.value
      if webSessionRenewal == renewal {
        webSessionRenewal = nil
        // A sign-out or another sign-in while Steam answered keeps what it set.
        if steamWebSession == session {
          steamWebSession = renewed
          persist(renewed)
        }
      }
      return steamWebSession
    } catch {
      if webSessionRenewal == renewal { webSessionRenewal = nil }
      throw error
    }
  }

  /// Saves `session` for later launches. The store logs a failure.
  private func persist(_ session: SteamWebSession) {
    try? webSessions?.save(session)
  }

  /// Drops the session, and the saved one with it.
  private func forgetSteamWebSession() {
    webSessionRestore?.cancel()
    webSessionRenewal?.cancel()
    webSessionRenewal = nil
    steamWebSession = nil
    webSessions?.remove()
  }

  func loadPage(_ page: Int) {
    guard let committedQuery, page >= 1, page <= totalPages else { return }
    load(WorkshopRequest(query: committedQuery, page: page))
  }

  func retrySearch() {
    guard let failedRequest else { return }
    load(failedRequest)
  }

  /// Drops every in-flight fetch. Cached pages survive unless the query changed or the caller
  /// asked for fresh results; the new cache id keeps late completions of old fetches out.
  private func resetCache(for query: WorkshopQuery?) {
    for task in steamFetches.values { task.cancel() }
    for task in screenedFetches.values { task.cancel() }
    steamFetches = [:]
    screenedFetches = [:]
    cacheID = UUID()
    if let query {
      steamPages = [:]
      screenedPages = [:]
      pageStarts = [1: .start]
      pageCounts = [:]
      cacheQuery = query
    }
  }

  /// Starts, or joins, the fetch of one panel page for the current cache.
  private func fetchSteamPage(_ number: Int, query: WorkshopQuery) -> Task<WorkshopPage, Error> {
    if let task = steamFetches[number] { return task }
    let cacheID = cacheID
    let service = service
    let task = Task { [weak self] in
      defer { if let self, self.cacheID == cacheID { self.steamFetches[number] = nil } }
      let result: WorkshopPage
      if Self.fillsPages(query), let self {
        result = try await self.filledPage(number, query: query, cacheID: cacheID)
      } else {
        let account = query.source == .subscriptions ? try await self?.currentSteamWebSession() : nil
        result = try await service.page(for: query, page: number, account: account)
      }
      try Task.checkCancellation()
      // Only the cache that asked keeps the page; a superseded fetch is simply dropped.
      if let self, self.cacheID == cacheID {
        self.steamPages[number] = result
        self.onPreviewsAvailable?(result.items.compactMap(\.previewURL))
      }
      return result
    }
    steamFetches[number] = task
    return task
  }

  /// Whether a panel page is filled from several Steam pages: collections while an age rating
  /// is hidden, which Steam cannot apply to them, so its pages come back with gaps.
  private static func fillsPages(_ query: WorkshopQuery) -> Bool {
    query.source == .collections
      && WorkshopService.screensRatings(tags: query.tags, excludedTags: query.excludedTags)
  }

  /// A panel page of screened collections, filled from as many Steam pages as it takes, on from
  /// where the page before it stopped, so paging forward and back shows each collection once.
  /// A page jumped to before the one ahead of it was shown starts where the pages read so far
  /// suggest; that start, the page count and the result count are estimates.
  private func filledPage(_ number: Int, query: WorkshopQuery, cacheID: UUID) async throws -> WorkshopPage {
    let start = pageStarts[number] ?? estimatedStart(of: number)
    var position: SteamPosition? = start
    var items: [WorkshopItem] = []
    var steamPageCount = 1
    var steamCount = 0
    var read = 0
    while let current = position, items.count < Self.pageSize, read < Self.maxSteamPagesPerPage {
      // A search, refresh or another list replaced this cache: read no more of Steam for it.
      guard self.cacheID == cacheID, !Task.isCancelled else { throw CancellationError() }
      // The next Steam page is likely needed too; asking for it now overlaps the two fetches.
      if let known = screenedPages.values.first?.totalPages, current.page < min(Self.maxPages, known) {
        _ = fetchScreenedPage(current.page + 1, query: query, cacheID: cacheID)
      }
      let steam = try await fetchScreenedPage(current.page, query: query, cacheID: cacheID).value
      read += 1
      steamPageCount = min(Self.maxPages, max(1, steam.totalPages))
      steamCount = steam.totalCount
      let kept = steam.items.dropFirst(current.offset)
      let taken = kept.prefix(Self.pageSize - items.count)
      items += taken
      if taken.count < kept.count {
        position = SteamPosition(page: current.page, offset: current.offset + taken.count)
      } else {
        position = current.page < steamPageCount ? SteamPosition(page: current.page + 1, offset: 0) : nil
      }
    }
    guard self.cacheID == cacheID else { throw CancellationError() }
    if pageStarts[number] == nil { pageStarts[number] = start }
    pageCounts[number] = items.count
    guard let next = position else {
      // A page cut short by the read limit holds fewer than 30, so count what each one showed.
      let before = (1..<number).reduce(0) { $0 + (pageCounts[$1] ?? Self.pageSize) }
      return WorkshopPage(items: items, page: number, totalPages: number, totalCount: before + items.count)
    }
    if pageStarts[number + 1] == nil { pageStarts[number + 1] = next }
    let steamPagesPerPage = max(1, next.progress / Double(number))
    let remaining = Int(((Double(steamPageCount) - next.progress) / steamPagesPerPage).rounded())
    return WorkshopPage(
      items: items, page: number, totalPages: min(Self.maxPages, number + max(1, remaining)),
      totalCount: max(number * Self.pageSize, Int(Double(steamCount) / steamPagesPerPage)))
  }

  /// Where a panel page not reached from the one before it most likely starts: on from the
  /// nearest known start before it, at the rate the pages read so far consumed Steam's.
  private func estimatedStart(of number: Int) -> SteamPosition {
    let before = pageStarts.filter { $0.key < number }.max { $0.key < $1.key } ?? (key: 1, value: .start)
    let furthest = pageStarts.max { $0.key < $1.key } ?? (key: 1, value: .start)
    let rate = furthest.key > 1 ? max(1, furthest.value.progress / Double(furthest.key - 1)) : 1
    let page = Int(before.value.progress + Double(number - before.key) * rate) + 1
    let last = screenedPages.values.first.map { min(Self.maxPages, max(1, $0.totalPages)) } ?? page
    return SteamPosition(page: min(page, last), offset: 0)
  }

  /// Starts, or joins, the fetch of one screened Steam page of collections for the cache that
  /// asks, `cacheID`. A cache that was replaced gets nothing, so its query never reaches the new one.
  private func fetchScreenedPage(_ number: Int, query: WorkshopQuery, cacheID: UUID) -> Task<WorkshopPage, Error> {
    guard cacheID == self.cacheID else { return Task { throw CancellationError() } }
    if let page = screenedPages[number] { return Task { page } }
    if let task = screenedFetches[number] { return task }
    let service = service
    let task = Task { [weak self] in
      defer { if let self, self.cacheID == cacheID { self.screenedFetches[number] = nil } }
      let result = try await service.page(for: query, page: number, account: nil)
      try Task.checkCancellation()
      if let self, self.cacheID == cacheID { self.screenedPages[number] = result }
      return result
    }
    screenedFetches[number] = task
    return task
  }

  /// Steam's own `total_pages` is already clamped to 1,000; clamping again keeps the panel's
  /// page count within that limit whatever a page says, so no page beyond it is ever offered.
  private func publish(_ result: WorkshopPage, for request: WorkshopRequest) {
    var seen = Set<String>()
    items = result.items.filter { seen.insert($0.id).inserted }
    totalCount = result.totalCount
    totalPages = min(Self.maxPages, max(1, result.totalPages))
    reachableCount = min(result.totalCount, totalPages * Self.pageSize)
    page = min(totalPages, request.page)
    hasLoaded = true
    isDegraded = result.isDegraded
    committedQuery = request.query
    sourceTitle = result.title
    failedRequest = nil
    // A failed prefetch is simply retried as an ordinary load when the user gets there.
    if prefetchesNextPage, page < totalPages, steamPages[page + 1] == nil {
      _ = fetchSteamPage(page + 1, query: request.query)
    }
  }

  private func load(_ request: WorkshopRequest) {
    searchTask?.cancel()
    // A cache built for another query holds nothing this one can use.
    if cacheQuery != request.query { resetCache(for: request.query) }
    let token = UUID()
    generation = token
    errorMessage = nil
    // Paging back to a page already read shows it at once, never as loading.
    if let cached = steamPages[request.page] {
      isLoading = false
      publish(cached, for: request)
      return
    }
    isLoading = true
    searchTask = Task { [weak self] in
      guard let self else { return }
      defer { if self.generation == token { self.isLoading = false } }
      do {
        let result = try await self.fetchSteamPage(request.page, query: request.query).value
        guard self.generation == token, !Task.isCancelled else { return }
        self.publish(result, for: request)
      } catch {
        guard self.generation == token, !Task.isCancelled, !(error is CancellationError) else { return }
        AppLog.warn("Workshop \(request.query.source.key) page \(request.page) failed: \(error.localizedDescription)")
        if error is SteamSignInRequired {
          // The session ended: drop it and the stale tiles, so the panel offers signing in again.
          self.forgetSteamWebSession()
          self.clearResults()
        } else if self.committedQuery?.source != request.query.source {
          self.clearResults()
        }
        self.errorMessage = error.localizedDescription
        self.failedRequest = request
      }
    }
  }

  func cancelSearch() {
    searchTask?.cancel()
    resetCache(for: nil)
    generation = UUID()
    isLoading = false
  }

}

/// A place among Steam's screened pages: the page, and how many of the tiles it kept come before.
private struct SteamPosition: Equatable {
  static let start = SteamPosition(page: 1, offset: 0)
  var page: Int
  var offset: Int

  /// How many Steam pages lie before this place, a partly read one by the share read.
  var progress: Double { Double(page - 1) + Double(offset) / Double(WorkshopService.pageSize) }
}
