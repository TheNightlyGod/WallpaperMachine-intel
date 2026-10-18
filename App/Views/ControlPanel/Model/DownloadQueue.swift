import Foundation

/// Everything the title bar's Downloads button and the Downloads popover say, over the Steam jobs,
/// the retained requests and the pixiv saves together.
///
/// The batch is described as the Wallpaper Engine panel always did: several downloads can run at
/// once, so the button carries one job's own figures, or the batch's mean progress and summed
/// speed once more than one runs. The batch is done when its slowest job is, so one job without an
/// estimate leaves the batch without one. A finished sign-in is not a download and shows only
/// while it runs.
struct DownloadQueue: Equatable {
  /// Retained intents, waiting for a prerequisite or for the user.
  let requests: [DownloadRequestRow]
  /// Steam's jobs, then pixiv's.
  let downloads: [DownloadRow]
  /// Holding a slot.
  let active: [DownloadRow]
  /// Waiting for one.
  let queued: [DownloadRow]
  /// Failed, or needing the user's answer.
  let attention: [DownloadRow]
  /// The mean fraction of the active jobs that have one; nil when none has.
  let progress: Double?
  /// The sum of the active jobs' speeds in bytes per second.
  let bytesPerSecond: Double
  /// The time the slowest active job needs; nil unless every active job has an estimate.
  let secondsRemaining: Double?
  /// What the title bar's badge counts.
  let count: Int
  /// The batch in one line: "2 downloading · 42% · Network speed: 1.2 MB/s · 3 min left".
  let summary: String
  /// The popover footer's note about how many run at once.
  let note: String

  // MARK: Derived

  /// The whole percentage of `progress`, or nil while it is unknown.
  var percent: Int? { progress.map { Int(($0 * 100).rounded()) } }

  /// The title-bar button appears once there is anything to list.
  var isVisible: Bool { !downloads.isEmpty || !requests.isEmpty }

  /// A ring around the button while anything transfers: determinate with `progress`, or an arc
  /// that is not animated while no job has a figure.
  var showsRing: Bool { !active.isEmpty }

  var needsAttention: Bool { !attention.isEmpty }

  /// The button's tooltip and accessibility label.
  @MainActor
  var buttonLabel: String {
    let described = needsAttention ? L("\(summary) · needs attention") : summary
    return L("Downloads: \(described)")
  }

  /// The popover's rows, in order: running and queued jobs, then those that need review.
  var pending: [DownloadRow] { downloads.filter(\.isPending) }
  /// Failed, cancelled or paused jobs: unfinished business that stays visible with its recovery.
  var unresolved: [DownloadRow] { downloads.filter(\.isUnresolved) }
  /// Finished jobs, which the popover shows only on request.
  var succeeded: [DownloadRow] { downloads.filter { !$0.isPending && !$0.needsReview } }
  /// Clearing removes what is not under way.
  var canClearFinished: Bool { downloads.count > pending.count }

  /// One row of the popover: a retained request or a job.
  enum Entry: Identifiable, Equatable {
    case request(DownloadRequestRow)
    case job(DownloadRow)

    /// A job keeps one identity whether it runs, waits, is paused or failed, so the list redraws
    /// it in place as it changes section; a lazy stack keeps a stale row for an id that moves from
    /// one `ForEach` to another.
    var id: String {
      switch self {
      case .request(let request): "request:\(request.id)"
      case .job(let job): "\(job.source):\(job.id)"
      }
    }
  }

  /// The popover's rows in order, for one `ForEach`: the requests, the running and waiting jobs,
  /// those that need review, then the finished ones when they are shown.
  func entries(showingCompleted: Bool) -> [Entry] {
    requests.map(Entry.request) + (pending + unresolved).map(Entry.job)
      + (showingCompleted ? succeeded.map(Entry.job) : [])
  }

  /// What the popover says when it has no rows.
  @MainActor
  var emptyMessage: String {
    succeeded.isEmpty
      ? L("No downloads yet. Pick a Workshop wallpaper and choose Download.")
      : L("All downloads are complete.")
  }

  // MARK: Making

  /// - Parameters:
  ///   - steam: every Steam job, a finished sign-in included (it decides the footer note).
  ///   - pixiv: every pixiv save.
  ///   - slotLimit: how many Steam downloads run at once right now.
  @MainActor
  static func make(
    requests: [DownloadRequestRow], steam: [DownloadRow], pixiv: [DownloadRow], slotLimit: Int,
    locale: Locale? = nil
  ) -> DownloadQueue {
    let locale = locale ?? PanelLocale.shared.locale
    let downloads = steam.filter { !$0.isSignInOnly || $0.isPending } + pixiv
    let active = downloads.filter { $0.isPending && !$0.isQueued }
    let queued = downloads.filter { $0.isPending && $0.isQueued }
    let attention = downloads.filter(\.needsAttention)
    let measured = active.compactMap(\.clampedProgress)
    let progress =
      measured.isEmpty ? nil : min(max(measured.reduce(0, +) / Double(measured.count), 0), 1)
    let speed = active.compactMap(\.bytesPerSecond).filter(\.isFinite).reduce(0, +)
    let estimates = active.compactMap { $0.secondsRemaining.map(Double.init) }
    let remaining = !active.isEmpty && estimates.count == active.count ? estimates.max() : nil
    let count = requests.count + active.count + queued.count

    let summary = Self.summary(
      requests: requests.count, downloads: downloads.count, active: active, queued: queued.count,
      percent: progress.map { Int(($0 * 100).rounded()) }, speed: speed, remaining: remaining,
      locale: locale)
    return DownloadQueue(
      requests: requests, downloads: downloads, active: active, queued: queued,
      attention: attention, progress: progress, bytesPerSecond: speed, secondsRemaining: remaining,
      count: count, summary: summary,
      note: note(steam: steam, pixiv: pixiv, slotLimit: slotLimit))
  }

  @MainActor
  private static func summary(
    requests: Int, downloads: Int, active: [DownloadRow], queued: Int, percent: Int?,
    speed: Double, remaining: Double?, locale: Locale
  ) -> String {
    let percentText = percent.map { "\($0)%" } ?? ""
    let timeLeft = TransferFormat.timeLeft(remaining, locale: locale)
    let parts: [String]
    if active.count > 1 {
      parts = [
        L("\(active.count) downloading"), percentText,
        speed > 0 ? TransferFormat.rate(speed, locale: locale) : "", timeLeft,
      ]
    } else if let running = active.first {
      parts = [
        running.status.isEmpty ? L("Downloading") : running.status, percentText,
        TransferFormat.rate(running.bytesPerSecond, locale: locale), timeLeft,
      ]
    } else if requests > 0 {
      return requests == 1
        ? L("\(requests) download needs setup") : L("\(requests) downloads need setup")
    } else if queued > 0 {
      return L("\(queued) waiting to download")
    } else if downloads > 0 {
      return downloads == 1 ? L("\(downloads) download") : L("\(downloads) downloads")
    } else {
      return L("No downloads")
    }
    return parts.filter { !$0.isEmpty }.joined(separator: " · ")
  }

  /// A queue that holds only pixiv's saves says how those run; otherwise the Steam slots.
  @MainActor
  private static func note(steam: [DownloadRow], pixiv: [DownloadRow], slotLimit: Int) -> String {
    if !steam.contains(where: { !$0.isSignInOnly }) && !pixiv.isEmpty {
      return L("pixiv downloads run two at a time; paused downloads stay in the queue.")
    }
    return slotLimit > 1
      ? L(
        "Up to \(slotLimit) downloads run at once and share your saved sign-in; the rest wait in order. Steam may still ask you to approve a sign-in."
      )
      : L(
        "Downloads run one at a time; the rest wait in order. Steam may still ask you to approve a sign-in."
      )
  }
}
