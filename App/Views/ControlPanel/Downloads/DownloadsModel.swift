import Foundation
import Observation

/// The downloads as the window shows them: the Downloads popover, the download dialog and what
/// opens it, and the keys the controls start their actions under.
///
/// The queue itself is the controller's (`downloadQueue`, `steamDownloadRows`, ...). What lives
/// here is page state that no store holds: which popover is open, which item the dialog is open on,
/// what the person has typed into it, which of Steam's requests they have said **Not now** to, and
/// the timer that closes the hand-off card.
///
/// The dialog opens only on an explicit request (a ring, a button, Settings) or when Steam asks for
/// a password or a Steam Guard answer, which a download cannot finish without; a saved sign-in never
/// asks, so routine downloads stay on their tile. While it is open every change of the request and
/// the jobs is re-resolved (`DownloadDialogResolution`) and the dialog closes when it has nothing
/// left to say. Closing it never removes a request or cancels a job.
@MainActor
@Observable
final class DownloadsModel {
  unowned let controller: PanelController

  /// One opening of the dialog. A new object is made each time it opens, so a failure that arrives
  /// after the dialog was closed and opened again is told apart from the one that is on show and
  /// never leaks into it (it still reaches the error banner).
  @MainActor
  @Observable
  final class Session {
    /// The item the dialog is open on: a retained request's or a job's id, or the shared scene
    /// assets'.
    let target: String
    /// What the account form holds. Each request owns its account, so a dialog opened for another
    /// request can never submit this one's sign-in.
    var account: String
    var remembersSession: Bool
    /// Why the last action started in the dialog failed.
    fileprivate(set) var errorMessage: String?

    init(target: String, account: String, remembersSession: Bool) {
      self.target = target
      self.account = account
      self.remembersSession = remembersSession
    }
  }

  /// The dialog's opening on show, nil while it is closed.
  private(set) var session: Session?
  /// The stage the dialog shows now, which the next resolution reads: the hand-off card may only
  /// follow a sign-in that was on show.
  private(set) var stage: DownloadDialogResolution.Stage?
  /// The item whose hand-off card has been shown, so it starts its timer once.
  private(set) var handoffTarget: String?
  /// The requests the person closed with **Not now**: Steam's password or Steam Guard prompts, by
  /// job and what was asked. Asking for something else surfaces the dialog again.
  private(set) var dismissedAuth: Set<SteamAuthKey> = []

  /// The Downloads popover is open. It is the shell's `.downloads` popover, so opening it closes
  /// any other, a change of page closes it, and the shell's flag the support prompt waits behind
  /// is true exactly while it is up.
  var isQueuePopoverOpen: Bool {
    get { controller.shell.activePopover == .downloads }
    set {
      guard newValue != isQueuePopoverOpen else { return }
      // The finished downloads fold away on every opening and closing, as they always did.
      showsCompleted = false
      controller.shell.popover(.downloads).wrappedValue = newValue
    }
  }
  /// The Downloads popover lists finished downloads too, until it closes.
  var showsCompleted = false

  /// How the timers wait; tests give it a clock they fire by hand.
  @ObservationIgnored var sleep: @Sendable (Duration) async throws -> Void = {
    try await Task.sleep(for: $0)
  }
  @ObservationIgnored private var handoffTask: Task<Void, Never>?
  @ObservationIgnored private var loop: ObservationLoop?

  init(controller: PanelController) { self.controller = controller }

  // MARK: Cross-area contract (Settings and the support prompt use these)

  /// Opens the download dialog for a retained request or job, or for the shared scene resources
  /// when `requestID` is nil, as Settings › Library & Steam's Continue setup…, Finish sign-in… and
  /// Download from Steam… do. It closes again at once when that item has nothing to say.
  func openDialog(for requestID: String?) {
    open(requestID ?? WorkshopStore.sceneAssetsRequestID)
  }

  /// Whether the download dialog is on show, which the support prompt waits behind.
  var isDialogOpen: Bool { session != nil }

  // MARK: The dialog

  /// What the dialog is open on, or nil.
  var target: String? { session?.target }

  /// Where the dialog stands: its stage and what it says there. Nil while it is closed and when
  /// the item it is open on has nothing left to say (`reconcile()` then closes it).
  var resolution: DownloadDialogResolution? {
    guard let session else { return nil }
    return controller.resolveDownloadDialog(
      target: session.target, currentStage: stage, handoffTarget: handoffTarget)
  }

  /// A change of this value is a change of what the dialog is about, which moves focus; a
  /// progress update is not, so typing is never interrupted.
  var focusKey: String {
    guard let resolution else { return "" }
    let asking = resolution.job
    return [
      resolution.subjectID, String(describing: resolution.stage), asking?.prompt?.rawValue ?? "",
      asking?.challenge.map { String(describing: $0) } ?? "",
    ].joined(separator: "\u{0}")
  }

  private func open(_ target: String) {
    let seed = controller.downloadAccountSeed(for: target)
    handoffTask?.cancel()
    handoffTask = nil
    handoffTarget = nil
    stage = nil
    session = Session(
      target: target, account: seed.account, remembersSession: seed.remembersSession)
    // Opening a dialog closes whatever popover is open.
    isQueuePopoverOpen = false
    reconcile()
  }

  /// Not now, the close button and Escape. Silences exactly what Steam asks for right now, for
  /// every job that is asking (not only the one the dialog was open on), until it asks for
  /// something else.
  func closeDialog() {
    dismissedAuth.formUnion(SteamAuthKey.askingNow(in: controller.steamDownloadRows))
    session = nil
    stage = nil
    handoffTarget = nil
    handoffTask?.cancel()
    handoffTask = nil
  }

  /// Brings the dialog up to date with the requests and jobs: closes it when it has nothing left to
  /// say, adopts the stage it resolves to, starts the hand-off timer on first reaching the
  /// hand-off card, and, while it is closed, opens it for a prompt Steam is waiting on.
  func reconcile() {
    if session != nil {
      guard let resolution else {
        closeDialog()
        return
      }
      // Written only when it changed: the loop that calls this reads it, and a write that changes
      // nothing must not wake the loop again.
      if stage != resolution.stage { stage = resolution.stage }
      if resolution.beginsHandoff { beginHandoff(resolution.subjectID) }
    } else if controller.presentation.isVisible,
      let asking = controller.steamAuthRequestToSurface(
        dismissed: dismissedAuth, welcomeIsOpen: controller.shell.isWelcomeOpen)
    {
      open(asking.id)
    }
  }

  /// The signed-in card stays six seconds with its live progress, then the dialog steps aside on its
  /// own, unless it moved on to another item meanwhile.
  private func beginHandoff(_ target: String) {
    handoffTarget = target
    handoffTask?.cancel()
    handoffTask = Task { @MainActor [weak self, sleep] in
      do { try await sleep(DownloadDialogResolution.handoffDuration) } catch { return }
      guard let self, !Task.isCancelled, self.handoffTarget == target,
        self.session?.target == target
      else { return }
      self.closeDialog()
    }
  }

  /// Follows the requests and the jobs while the window is up: the dialog resolves again when one
  /// changes, and a password prompt arriving opens it. Called by the host view.
  func start() {
    if loop == nil {
      loop = ObservationLoop(
        track: { [weak self] in self?.trackDialogInputs() },
        onChange: { [weak self] in self?.reconcile() })
    }
    loop?.start()
    reconcile()
  }

  func stop() {
    loop?.stop()
    handoffTask?.cancel()
    handoffTask = nil
  }

  /// Registers what `reconcile` reads: while closed, whether any job is waiting on the user (and
  /// whether the window can show it); while open, the item the dialog is about.
  private func trackDialogInputs() {
    _ = controller.presentation.isVisible
    _ = controller.shell.isWelcomeOpen
    if session != nil {
      _ = resolution
    } else {
      for job in controller.workshop.downloader.downloads {
        _ = job.isPending
        _ = job.isQueued
        _ = job.worker.prompt
        _ = job.worker.steamGuardChallenge
      }
    }
  }

  // MARK: What the dialog's controls do

  /// Starts an action from inside the dialog. A failure shows in the dialog as well as in the
  /// error banner, unless this dialog was closed (and perhaps opened again) before it arrived: only
  /// the opening that started it may show it. A failure never loses the typed account or the
  /// choice to keep the session.
  @discardableResult
  func perform(
    _ key: String? = nil, policy: PanelActionCoordinator.Policy = .dropDuplicates,
    _ operation: @escaping @MainActor () async throws -> Void
  ) -> Task<Void, Never> {
    guard let session else { return controller.launch(key, policy: policy, operation: operation) }
    session.errorMessage = nil
    return controller.launch(key, policy: policy) { [weak self, session] in
      do {
        try await operation()
      } catch {
        if self?.session === session, !(error is CancellationError) {
          session.errorMessage = error.localizedDescription
        }
        throw error
      }
    }
  }

  /// The account form's **Continue** and the resources stage's **Download from Steam**.
  @discardableResult
  func continueDownload(includeResources: Bool) -> Task<Void, Never>? {
    guard let session else { return nil }
    let id = session.target
    let account = session.account
    let remembers = session.remembersSession
    return perform(PanelActionCoordinator.key("continueDownload", id: id)) { [controller] in
      try await controller.continueDownload(
        id: id, account: account, remembersSession: remembers, includeResources: includeResources)
    }
  }

  /// Answers Steam's password or Steam Guard prompt. The secret is passed straight on: it is not
  /// stored, logged or kept in any state of the panel, and the caller clears its field first.
  @discardableResult
  func submitSecret(_ secret: String, toJob id: String) -> Task<Void, Never> {
    perform(PanelActionCoordinator.key("downloadInput", id: id)) { [controller] in
      try await controller.submitDownloadInput(secret, toJob: id)
    }
  }

  /// **Change account**: stops this job, keeps its wallpaper as a request with no account, and
  /// reopens the dialog on it, which is now at the account stage.
  func changeAccount(forJob id: String) {
    perform(PanelActionCoordinator.key("changeAccount", id: id)) { [weak self, controller] in
      try await controller.changeDownloadAccount(id: id)
      self?.open(id)
    }
  }

  /// **Cancel this download** in the auth stage.
  func cancelFromDialog(_ id: String) {
    perform(PanelActionCoordinator.key("downloadCancel", id: id)) { [controller] in
      try await controller.cancelDownload(id: id)
    }
  }

  // MARK: The setup stage

  /// The setup stage's buttons. Each starts from inside the dialog like the other stages' actions,
  /// so a failure (a copy that cannot be approved any more, a folder that is not SteamCMD) reads in
  /// the dialog, where the sheet hides the banner behind it.
  @discardableResult
  func installSteamCMD() -> Task<Void, Never> {
    perform(PanelActionCoordinator.key("setupInstall")) { [controller] in
      try await controller.installSteamCMD()
    }
  }

  @discardableResult
  func locateSteamCMD() -> Task<Void, Never> {
    perform(PanelActionCoordinator.key("setupLocate")) { [controller] in
      try await controller.locateSteamCMD()
    }
  }

  @discardableResult
  func approveSteamCMD() -> Task<Void, Never> {
    perform(PanelActionCoordinator.key("setupApprove")) { [controller] in
      try await controller.approveSteamCMD()
    }
  }

  @discardableResult
  func cancelSteamCMDSetup() -> Task<Void, Never> {
    perform(PanelActionCoordinator.key("setupCancel")) { [controller] in
      try await controller.cancelSteamCMDSetup()
    }
  }

  @discardableResult
  func revealSteamCMDCandidate() -> Task<Void, Never> {
    perform(PanelActionCoordinator.key("setupRevealCandidate")) { [controller] in
      try await controller.revealSteamCMDCandidate()
    }
  }

  @discardableResult
  func discardSteamCMDCandidate() -> Task<Void, Never> {
    perform(PanelActionCoordinator.key("setupDiscardCandidate")) { [controller] in
      try await controller.discardSteamCMDCandidate()
    }
  }

  /// The resources stage's **Use an existing installation**.
  @discardableResult
  func locateSceneAssets() -> Task<Void, Never> {
    perform(PanelActionCoordinator.key("locateAssets")) { [controller] in
      try await controller.locateSceneAssets()
    }
  }

  /// **Show downloads**: closes the dialog and opens the Downloads popover.
  func showDownloadsFromDialog() {
    closeDialog()
    isQueuePopoverOpen = true
  }

  // MARK: Starting and following a download

  /// **Download**, **Download and apply**, a double-click on a tile. The request is kept, and the
  /// dialog opens when something is missing (SteamCMD, the account, the consent to download the
  /// shared resources) or Steam asks for a password at once; otherwise the download simply starts
  /// and its tile reports it.
  @discardableResult
  func requestDownload(_ item: WorkshopItem, apply: Bool = false) -> Task<Void, Never> {
    controller.launch(PanelActionCoordinator.key("requestDownload", id: item.id)) {
      [weak self, controller] in
      try await controller.requestDownload(item: item, apply: apply)
      if let target = controller.downloadDialogTarget(afterRequesting: item.id) {
        self?.openDialog(for: target)
      }
    }
  }

  /// **Get shared resources** and Settings' Download from Steam…: asks for the shared scene
  /// resources, and opens the dialog when a prerequisite is missing.
  @discardableResult
  func requestSceneAssets() -> Task<Void, Never> {
    controller.launch(PanelActionCoordinator.key("requestDownload", id: "")) { [controller] in
      try await controller.getSceneResources()
    }
  }

  /// What clicking a download ring does for a Workshop tile or the matching inspector button.
  func perform(_ action: TileDownloadState.Action, forItem id: String) {
    switch action {
    case .continueSetup:
      openDialog(for: id)
    case .resume:
      controller.launch(PanelActionCoordinator.key("downloadResume", id: id)) { [controller] in
        try await controller.resumeDownload(id: id)
      }
    case .cancel:
      controller.launch(PanelActionCoordinator.key("downloadCancel", id: id)) { [controller] in
        try await controller.cancelDownload(id: id)
      }
    case .retry:
      controller.launch(PanelActionCoordinator.key("downloadRetry", id: id)) { [controller] in
        try await controller.retryDownload(id: id)
      }
    }
  }

  // MARK: The Downloads popover

  /// The action key of a row's control, so it can disable itself while its action is pending.
  static func key(_ action: String, row: DownloadRow) -> String {
    let name: String
    switch (action, row.source) {
    case ("pause", .pixiv): name = "pixivPause"
    case ("cancel", .pixiv): name = "pixivCancel"
    case ("resume", .pixiv): name = "pixivResume"
    case ("retry", .pixiv): name = "pixivRetryDownload"
    case ("pause", .steam): name = "downloadPause"
    case ("cancel", .steam): name = "downloadCancel"
    case ("resume", .steam): name = "downloadResume"
    default: name = "downloadRetry"
    }
    return PanelActionCoordinator.key(name, id: row.id)
  }

  func pause(_ row: DownloadRow) {
    controller.launch(Self.key("pause", row: row)) { [controller] in
      try await controller.pauseDownload(row)
    }
  }

  func cancel(_ row: DownloadRow) {
    controller.launch(Self.key("cancel", row: row)) { [controller] in
      try await controller.cancelDownload(row)
    }
  }

  func resume(_ row: DownloadRow) {
    controller.launch(Self.key("resume", row: row)) { [controller] in
      try await controller.resumeDownload(row)
    }
  }

  func retry(_ row: DownloadRow) {
    controller.launch(Self.key("retry", row: row)) { [controller] in
      try await controller.retryDownload(row)
    }
  }

  func removeRequest(_ request: DownloadRequestRow) {
    // The dialog goes first when it is open on this request, as it always did.
    if session?.target == request.id { closeDialog() }
    controller.launch(PanelActionCoordinator.key("removeDownloadRequest", id: request.id)) {
      [controller] in
      try await controller.removeDownloadRequest(id: request.id)
    }
  }

  func clearFinished() {
    controller.launch(PanelActionCoordinator.key("clearDownloads")) { [controller] in
      try await controller.clearDownloads()
    }
  }

  func showLogs() {
    controller.launch(PanelActionCoordinator.key("showLogs")) { [controller] in
      try await controller.showLogs()
    }
  }

  /// Opens the Downloads popover, as the inspector's **Show in downloads** does.
  func showDownloads() { isQueuePopoverOpen = true }
}
