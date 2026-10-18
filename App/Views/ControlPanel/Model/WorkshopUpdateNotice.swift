import Foundation

/// What the inspector tells about an installed Workshop wallpaper whose author changed it since it
/// was installed, or whose update is on its way: one click downloads the new version, which
/// replaces the installed one once it has arrived whole.
struct WorkshopUpdateNotice: Equatable {
  /// Where the update is, once it has been asked for.
  enum Progress: Equatable {
    case waiting
    case downloading(percent: Int?)
  }

  /// The notice's one button.
  enum Action: Equatable {
    /// The update is under way: look at the Downloads list.
    case showInDownloads
    /// The update's request waits for SteamCMD or the account: reopen the dialog.
    case continueSetup
    /// Ask for the update.
    case update
  }

  /// When the author last changed it, if Steam said.
  let updatedAt: Date?
  /// Nil until the update is asked for.
  let progress: Progress?
  let action: Action

  /// The notice for an installed wallpaper, or nil when it has no update and none is downloading.
  /// `update` is the Workshop's newer version, `request` and `job` the update's own download.
  static func make(update: WorkshopItem?, request: DownloadRequestRow?, job: DownloadRow?)
    -> WorkshopUpdateNotice?
  {
    let underway = job?.isPending == true
    guard update != nil || underway else { return nil }
    var progress: Progress?
    if let job, underway {
      let percent = job.clampedProgress.map { Int(($0 * 100).rounded()) }
      progress = job.isQueued ? .waiting : .downloading(percent: percent)
    }
    return WorkshopUpdateNotice(
      updatedAt: update?.timeUpdated, progress: progress,
      action: underway ? .showInDownloads : request != nil ? .continueSetup : .update)
  }

  /// The notice's sentence. The date is the numeric one of `locale`.
  @MainActor
  func message(locale: Locale? = nil) -> String {
    switch progress {
    case .waiting?: return L("The update is waiting to download.")
    case .downloading(let percent?)?: return L("Downloading the update… \(percent)%")
    case .downloading(nil)?: return L("Downloading the update…")
    case nil:
      guard let updatedAt else { return L("Its author updated it on the Workshop.") }
      let locale = locale ?? PanelLocale.shared.locale
      let date = updatedAt.formatted(Date.FormatStyle(date: .numeric, time: .omitted).locale(locale))
      return L("Its author updated it on the Workshop on \(date).")
    }
  }
}
