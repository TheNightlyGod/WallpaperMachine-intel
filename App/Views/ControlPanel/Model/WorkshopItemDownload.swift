import Foundation

/// What Discover's inspector offers and says about one item's download.
///
/// One request or job decides the primary action, in this order: a collection is opened; a retained
/// request is resumed or continued; a paused job is resumed; a running one is finished (when Steam
/// waits for the user) or watched; anything else is downloaded, again after a failure. **Download
/// and apply** sits beside Download only there, so it never appears for an installed wallpaper, a
/// download under way, or one waiting for setup.
struct WorkshopItemDownload: Equatable {
  enum Action: Equatable {
    /// A collection is a list: open it to see its wallpapers.
    case openCollection
    /// A paused retained request or job: resume it.
    case resume
    /// A retained request waits for SteamCMD, the account or the consent: reopen the dialog.
    case continueSetup
    /// Steam waits for a password or a Steam Guard answer: reopen the dialog.
    case finishSignIn
    /// A job waits for a slot or transfers: the primary button reads `label` and opens the
    /// Downloads list, and a quiet one removes it from the queue (`isQueued`) or cancels it.
    case inProgress(label: String, isQueued: Bool)
    /// Nothing is under way. `canApply` offers **Download and apply** beside it.
    case download(again: Bool, canApply: Bool)
  }

  let action: Action
  let request: DownloadRequestRow?
  let job: DownloadRow?
  /// The wallpaper is installed, so the download controls give way to the installed ones.
  let isInstalled: Bool
  /// A running job's progress bar and the line under it ("status · amount · speed · time left").
  /// The bar is determinate when `progress` is a number.
  let showsProgress: Bool
  let progress: Double?
  let statusLine: String
  /// What a retained request waits for.
  let stageHint: String?
  /// The wallpaper will be applied to the target display once it has arrived.
  let appliesOnArrival: Bool
  /// Why a wallpaper that arrived was left alone, unless the target display shows it already
  /// (`PanelController.workshopApplyNote(for:)`).
  let applyNote: String?
  /// What the failed download said, for a wallpaper that is not installed.
  let failure: String?
  /// **Download and apply** is offered beside Download: the item is not installed, nothing is under
  /// way for it, and the target display can take a wallpaper that can run.
  var offersDownloadAndApply: Bool {
    if !isInstalled, case .download(_, canApply: true) = action { return true }
    return false
  }
  /// A download or a request exists, so the inspector offers to show the Downloads list.
  var showsInDownloads: Bool { request != nil || job != nil }
  /// A download of an installed wallpaper finished cleanly, which moves **Show in library** up
  /// beside **Show in downloads**.
  var hasFinishedDownload: Bool {
    guard let job else { return false }
    return !job.isPending && !job.hasError
  }

  /// - Parameters:
  ///   - canApplyToTarget: the target display is enabled and shows a wallpaper of its own.
  ///   - applyNote: why the wallpaper that arrived was left alone, if it was.
  @MainActor
  static func make(
    item: WorkshopItem, request: DownloadRequestRow?, job: DownloadRow?, isInstalled: Bool,
    canApplyToTarget: Bool, applyNote: String?,
    locale: Locale? = nil
  ) -> WorkshopItemDownload {
    let locale = locale ?? PanelLocale.shared.locale
    let percent = job?.clampedProgress.map { Int(($0 * 100).rounded()) }
    let action: Action
    if item.isCollection {
      action = .openCollection
    } else if let request {
      action = request.isPaused ? .resume : .continueSetup
    } else if let job, job.isPaused, !job.isPending {
      action = .resume
    } else if let job, job.isPending {
      if job.prompt != nil || job.challenge != nil {
        action = .finishSignIn
      } else {
        let label =
          job.isQueued
          ? L("Waiting to download")
          : percent.map { L("Downloading \($0)%") } ?? L("Downloading")
        action = .inProgress(label: label, isQueued: job.isQueued)
      }
    } else {
      action = .download(
        again: job?.hasError ?? false,
        canApply: item.canRunOnMac && canApplyToTarget)
    }

    let showsProgress = !isInstalled && job.map { $0.isPending && !$0.isQueued } ?? false
    var statusLine = ""
    if showsProgress, let job {
      let transfer = TransferFormat.transfer(
        job.transferProgress, includePercent: false, locale: locale)
      statusLine = transfer.isEmpty ? job.status : "\(job.status) · \(transfer)"
    }
    var appliesOnArrival = false
    if let request {
      appliesOnArrival = request.appliesOnArrival
    } else if let job, job.isPending {
      appliesOnArrival = job.appliesOnArrival
    }
    var failure: String?
    if !isInstalled, let job, !job.isPending, job.hasError { failure = job.errorMessage }
    return WorkshopItemDownload(
      action: action, request: request, job: job, isInstalled: isInstalled,
      showsProgress: showsProgress, progress: showsProgress ? job?.clampedProgress : nil,
      statusLine: statusLine, stageHint: request?.stage.hint,
      appliesOnArrival: appliesOnArrival, applyNote: applyNote, failure: failure)
  }
}
