import Foundation

/// The Workshop download pipeline as the panel drives it: the intent queue (a request keeps the
/// wallpaper the user asked for while SteamCMD, the Steam account and the consent for shared scene
/// resources are resolved in turn), the Steam sign-in and the password and Steam Guard answers.
///
/// A download is owned by the app, not the panel: the Workshop store continues a retained request
/// the moment its prerequisite completes, hidden window or none, and closing the panel never stops
/// work. What the panel adds is the state to show and the actions to start, and every action that
/// can fail at once reports the downloader's or the queue file's complaint as its own error.
extension PanelController {
  // MARK: State

  /// The Downloads button and popover: the batch, the retained requests and the rows, Steam's and
  /// pixiv's together.
  var downloadQueue: DownloadQueue {
    DownloadQueue.make(
      requests: downloadRequestRows, steam: steamDownloadRows,
      pixiv: pixivDownloadRows.map(DownloadRow.init), slotLimit: workshop.downloader.slotLimit)
  }

  /// Every Steam job, in queue order, as plain values.
  var steamDownloadRows: [DownloadRow] {
    workshop.downloader.downloads.map(mediaDownloadRow)
  }

  /// The Steam job of this item (or `WorkshopStore.sceneAssetsRequestID`, or the sign-in's id).
  func steamDownloadRow(for id: String) -> DownloadRow? {
    workshop.downloader.downloads.first { $0.id == id }.map(mediaDownloadRow)
  }

  /// The sign-in-only job the first-run guide and Settings start, while it exists.
  var steamSignInRow: DownloadRow? { steamDownloadRow(for: WorkshopStore.signInRequestID) }

  /// Every retained request, with the prerequisite each still needs.
  var downloadRequestRows: [DownloadRequestRow] {
    workshop.downloadRequests.map(mediaRequestRow)
  }

  /// The retained request for this item (or the shared scene assets).
  func downloadRequestRow(for id: String) -> DownloadRequestRow? {
    workshop.downloadRequests.first { $0.id == id }.map(mediaRequestRow)
  }

  /// SteamCMD's state: whether it is installed, being set up, or needs the user's approval.
  var steamSetup: SteamSetupState { SteamSetupState(workshop.steamCMDSetup) }

  /// The Steam account the next download would use and what the sign-in will remember.
  var steamAccount: SteamAccountState {
    SteamAccountState(
      suggested: workshop.suggestedAccount, saved: workshop.downloader.savedAccount,
      remembersSession: workshop.downloader.rememberSessionWhileRunning ?? remembersSession,
      slotLimit: workshop.downloader.slotLimit,
      downloadsRunOneAtATimeAfterConflict: workshop.downloader.sessionConflictDetected)
  }

  /// What the dialog's account form starts with for the item: the request's own account (each
  /// request owns its account, so switching requests never submits another one's sign-in), else
  /// the job's, else the account the next download would use; and whether to keep the session.
  func downloadAccountSeed(for id: String) -> DownloadAccountSeed {
    let request = downloadRequestRow(for: id)
    return DownloadAccountSeed(
      account: request?.account ?? steamDownloadRow(for: id)?.account ?? steamAccount.suggested,
      remembersSession: request?.rememberSession ?? steamAccount.remembersSession)
  }

  /// The job whose password or Steam Guard request should open the download dialog by itself, or
  /// nil. `dismissed` holds the requests the user closed with **Not now**; `welcomeIsOpen` keeps
  /// the first-run guide's own sign-in out of the panel's dialog.
  func steamAuthRequestToSurface(dismissed: Set<SteamAuthKey>, welcomeIsOpen: Bool) -> DownloadRow? {
    SteamAuthKey.surfaced(in: steamDownloadRows, dismissed: dismissed, welcomeIsOpen: welcomeIsOpen)
  }

  /// Where the download dialog stands for the item it is open on, or nil when it should close. A
  /// view asks again whenever a request or a job changes.
  func resolveDownloadDialog(
    target: String, currentStage: DownloadDialogResolution.Stage?, handoffTarget: String?
  ) -> DownloadDialogResolution? {
    DownloadDialogResolution.resolve(
      target: target, request: downloadRequestRow(for: target), own: steamDownloadRow(for: target),
      sceneAssets: steamDownloadRow(for: WorkshopStore.sceneAssetsRequestID),
      currentStage: currentStage, handoffTarget: handoffTarget)
  }

  /// The item the download dialog should open on after a request for `id` (nil for the shared
  /// scene assets): its request while a prerequisite is missing, else its job while Steam asks the
  /// user something, else nothing, so a download with a saved sign-in just starts on its tile.
  func downloadDialogTarget(afterRequesting id: String?) -> String? {
    let target = id ?? WorkshopStore.sceneAssetsRequestID
    if let request = downloadRequestRow(for: target), request.stage != .ready { return request.id }
    if let job = steamDownloadRow(for: target), job.isRunning,
      job.prompt != nil || job.challenge != nil
    {
      return target
    }
    return nil
  }

  private func mediaDownloadRow(_ job: WorkshopDownload) -> DownloadRow {
    DownloadRow(job, appliesOnArrival: workshop.appliesOnArrival(job.id))
  }

  private func mediaRequestRow(_ request: WorkshopDownloadRequest) -> DownloadRequestRow {
    DownloadRequestRow(
      request, stage: workshop.stage(for: request),
      appliesOnArrival: workshop.appliesOnArrival(request.id))
  }

  /// Whether a wallpaper is in the library. The ids are read off the library once per change and
  /// kept, so asking for every tile and row on every progress tick never walks the library.
  func mediaLibraryContains(_ id: String) -> Bool {
    let revision = store.libraryPresentationRevision
    if let cached = mediaLibraryIndex, cached.revision == revision { return cached.ids.contains(id) }
    let ids = Set(store.librarySnapshot.wallpapers.map(\.id))
    mediaLibraryIndex = (revision, ids)
    return ids.contains(id)
  }

  /// The target display as **Download and apply**, a double-click and an apply button see it: one
  /// that is enabled and shows a wallpaper of its own can take a wallpaper; a mirror or a disabled
  /// display cannot.
  var mediaApplyTarget: MediaApplyTarget {
    _ = revisions.navigation
    let id = navigation.targetDisplayID
    let display = store.settingsSnapshot.displays.first { $0.displayId == id }
    return MediaApplyTarget(
      canShowWallpaper: display.map { $0.enabled && $0.mode == .standalone } ?? false,
      wallpaperID: store.monitorInformationSnapshot.rows.first { $0.displayId == id }?.wallpaperId)
  }

  // MARK: Requests

  /// Asks for a Workshop wallpaper. One click keeps the intent: the Workshop store retains the
  /// request and reports which prerequisite it waits on (SteamCMD, the account, the consent for
  /// shared resources), or starts at once when all are met. A caller opens the dialog afterwards
  /// when `downloadDialogTarget(afterRequesting:)` names one.
  ///
  /// With `apply` the wallpaper is applied to the display the panel targets *now* once it has
  /// arrived, unless the user chooses another wallpaper for it meanwhile; the display must be one
  /// that can show a wallpaper of its own, and is refused before anything is queued otherwise.
  /// The item must be one the store knows, and a collection is refused: it is a list, opened and
  /// downloaded one wallpaper at a time.
  func requestDownload(item: WorkshopItem, apply: Bool = false) async throws {
    guard let found = workshop.workshopItem(id: item.id) else { throw InvalidControlValue() }
    guard !found.isCollection else {
      throw WallpaperActionError(
        message: L("A collection can’t be downloaded as one. Open it to download its wallpapers."))
    }
    let displayID = navigation.targetDisplayID
    if apply { try store.validateActivationTarget(displayID) }
    try await run(.queued) {
      workshop.requestDownload(
        item: found, rememberSession: remembersSession, bridge: store,
        applyTo: apply ? displayID : nil)
      try checkDownloadError()
    }
  }

  /// Asks for Wallpaper Engine's shared scene resources, which scene wallpapers need to play: one
  /// job shared by every scene that waits for it.
  func requestSceneAssets() async throws {
    try await run(.queued) {
      workshop.requestDownload(item: nil, rememberSession: remembersSession, bridge: store)
      try checkDownloadError()
    }
  }

  /// **Get shared resources**, and Apply on a scene while they are missing: asks for the shared
  /// scene resources and opens the download dialog when the request waits on something (SteamCMD,
  /// the account, the consent to download them). A download already under way is shown instead.
  func getSceneResources() async throws {
    try await requestSceneAssets()
    if let target = downloadDialogTarget(afterRequesting: nil) {
      downloads.openDialog(for: target)
    }
  }

  /// Supplies what a retained request waits on, the account and the consent, and resumes it.
  /// `includeResources` is the user's explicit go-ahead to download the shared resources (several
  /// gigabytes). The account is trimmed, as the dialog's field always was before it was sent, and
  /// the choice to keep the session is remembered even if the request is then refused. A name the
  /// downloader rejects (such as `anonymous`) leaves the request in place, marked refused, with the
  /// reason as this action's error. An id that is neither a request nor a known item is refused.
  func continueDownload(
    id: String, account: String, remembersSession keepsSession: Bool, includeResources: Bool
  ) async throws {
    try await run(.queued) {
      remembersSession = keepsSession
      guard
        workshop.continueDownload(
          id: id, account: account.trimmingCharacters(in: .whitespacesAndNewlines),
          rememberSession: keepsSession, includeResources: includeResources, bridge: store)
      else { throw InvalidControlValue() }
      try checkDownloadError()
    }
  }

  /// Signs in to Steam without downloading anything, so the account and its saved sign-in are in
  /// place before the first download (the first-run guide and Settings do this). It rides the same
  /// ladder as a download: SteamCMD must be set up first. The password is never an argument: Steam
  /// asks for it through the job's own prompt, answered with `submitDownloadInput`.
  func steamSignIn(account: String, remembersSession keepsSession: Bool) async throws {
    try await run(.queued) {
      remembersSession = keepsSession
      workshop.requestSignIn(account: account, rememberSession: keepsSession, bridge: store)
      try checkDownloadError()
    }
  }

  /// Drops a retained request, its apply choice and its kept checkpoint. A request that just
  /// started is already gone, so this is not an error.
  func removeDownloadRequest(id: String) async throws {
    try await run(.queued) { workshop.removeDownloadRequest(id: id) }
  }

  /// "Change account": stops exactly this running job and keeps its wallpaper as a request with no
  /// account, marked refused, so nothing signs in again under the name the user rejected.
  func changeDownloadAccount(id: String) async throws {
    try await run(.queued) {
      guard let job = workshop.downloader.downloads.first(where: { $0.id == id }) else {
        throw InvalidControlValue()
      }
      await workshop.changeDownloadAccount(id: job.id)
    }
  }

  // MARK: Controlling jobs

  /// Cancels a download and removes any retained request and apply choice for it. It never waits
  /// behind a renderer command and the id is not checked: cancelling something already gone is
  /// fine.
  func cancelDownload(id: String) async throws {
    try await run(.immediate) { workshop.cancelDownload(id: id) }
  }

  /// Pauses a running or queued download, keeping its content. The sign-in job cannot be paused.
  func pauseDownload(id: String) async throws {
    try await run(.immediate) {
      guard let job = workshop.downloader.downloads.first(where: { $0.id == id }) else {
        throw InvalidControlValue()
      }
      workshop.downloader.pause(job)
    }
  }

  /// Resumes a paused request, else a paused job, in a fresh private SteamCMD runtime. An id that
  /// is neither is refused.
  func resumeDownload(id: String) async throws {
    try await run(.queued) {
      if !workshop.resumeDownloadRequest(id: id, bridge: store) {
        guard let job = workshop.downloader.downloads.first(where: { $0.id == id }) else {
          throw InvalidControlValue()
        }
        workshop.resumeDownload(job, bridge: store)
      }
      try checkDownloadError()
    }
  }

  /// Tries a failed or cancelled download again. It re-enters the same prerequisite ladder, and the
  /// shared resources need their consent again. A job that is still under way is refused.
  func retryDownload(id: String) async throws {
    try await run(.queued) {
      guard let job = workshop.downloader.downloads.first(where: { $0.id == id }), !job.isPending
      else { throw InvalidControlValue() }
      workshop.continueDownload(
        id: job.id, account: job.account, rememberSession: remembersSession,
        includeResources: false, bridge: store)
      try checkDownloadError()
    }
  }

  /// Answers the password or Steam Guard prompt of a running job.
  ///
  /// The secret goes straight to SteamCMD's terminal: it is never logged, never stored, never part
  /// of any state the panel keeps. It must be a single line, not empty and without NUL, and the job
  /// must be asking. The caller clears its field the moment it hands the value over.
  func submitDownloadInput(_ secret: String, toJob id: String) async throws {
    try await run(.immediate) {
      guard let job = workshop.downloader.downloads.first(where: { $0.id == id }),
        job.worker.prompt != nil, !secret.isEmpty,
        !secret.contains(where: { $0.isNewline || $0 == "\0" })
      else { throw InvalidControlValue() }
      job.worker.submitSecret(secret)
    }
  }

  /// Clears the finished, failed and cancelled downloads, both queues' (paused ones stay), and
  /// every note about a wallpaper that arrived and was not applied.
  func clearDownloads() async throws {
    try await run(.queued) {
      workshop.clearDownloadActivity()
      pixiv.downloads.clearFinished()
    }
  }

  /// Forgets the saved Steam sign-in on this Mac after asking. Other Steam devices stay signed in.
  /// Not while a download is active or waiting, which the downloader says as this action's error.
  func logOutSteam() async throws {
    try await run(.queued) {
      let account = workshop.downloader.savedAccount ?? ""
      guard
        await dialogs.confirm(
          L("Log out of Steam?"),
          detail: L(
            "The saved sign-in for \(account) will be removed from this Mac. Other Steam devices stay signed in, and the next download asks you to sign in again."
          ),
          button: L("Log Out"))
      else { return }
      workshop.downloader.forgetSavedAccount()
      if let message = workshop.downloader.errorMessage { throw WallpaperActionError(message: message) }
    }
  }

  // MARK: Rows of the shared Downloads list

  /// The Downloads list shows Steam's jobs and pixiv's saves together. Each of these sends its
  /// action to the queue the row belongs to, so the list needs no knowledge of which is which.
  func pauseDownload(_ row: DownloadRow) async throws {
    switch row.source {
    case .steam: try await pauseDownload(id: row.id)
    case .pixiv: try await pixivPause(id: row.id)
    }
  }

  func cancelDownload(_ row: DownloadRow) async throws {
    switch row.source {
    case .steam: try await cancelDownload(id: row.id)
    case .pixiv: try await pixivCancel(id: row.id)
    }
  }

  func resumeDownload(_ row: DownloadRow) async throws {
    switch row.source {
    case .steam: try await resumeDownload(id: row.id)
    case .pixiv: try await pixivResume(id: row.id)
    }
  }

  func retryDownload(_ row: DownloadRow) async throws {
    switch row.source {
    case .steam: try await retryDownload(id: row.id)
    case .pixiv: try await pixivRetryDownload(id: row.id)
    }
  }

  /// Throws what the downloader or the queue file last complained of, after a request that can
  /// fail at once: a refused account, a queue that could not be saved.
  func checkDownloadError() throws {
    if let message = workshop.downloader.errorMessage ?? workshop.downloadPersistenceError {
      throw WallpaperActionError(message: message)
    }
  }
}

/// The target display, as far as a wallpaper going to it is concerned.
struct MediaApplyTarget: Equatable {
  /// The display is enabled and shows a wallpaper of its own, so a wallpaper can be applied to it.
  let canShowWallpaper: Bool
  /// What the display shows now.
  let wallpaperID: String?
}

/// The Steam account the downloads use and what signing in will remember.
struct SteamAccountState: Equatable {
  /// What a new download's account field starts with: the running download's account, else the
  /// name typed last, else the saved sign-in's.
  let suggested: String
  /// The account whose sign-in is saved on this Mac.
  let saved: String?
  /// Whether the sign-in is kept while downloads run: a running download's own choice, else the
  /// panel's last.
  let remembersSession: Bool
  /// How many downloads run at once: the user's setting, or one after Steam ended a session.
  let slotLimit: Int
  /// Steam ended one session for another of this app's, so downloads run one at a time until the
  /// app reopens.
  let downloadsRunOneAtATimeAfterConflict: Bool
}

/// What the download dialog's account form starts with.
struct DownloadAccountSeed: Equatable {
  let account: String
  let remembersSession: Bool
}
