import Foundation

/// A Steam job or a pixiv save as the queue, the tiles and the download dialog read it: every
/// field copied out of the live job, so the rules over it are plain values a test can build.
///
/// Both kinds of download share one shape, as the web panel merged pixiv's into Steam's. A pixiv
/// row has no speed, estimate, prompt or account, and its `status` is the sentence the queue
/// shows for its state.
struct DownloadRow: Identifiable, Equatable {
  enum Source: Equatable {
    case steam, pixiv
  }

  /// The job's id: a Workshop item's, `WorkshopStore.sceneAssetsRequestID` for the shared scene
  /// assets, `WorkshopStore.signInRequestID` for a sign-in that downloads nothing, or the library
  /// id a pixiv page is saved as.
  let id: String
  let source: Source
  /// The Workshop item or pixiv page this installs; nil for the shared assets and the sign-in.
  let wallpaperID: String?
  let title: String
  /// What the job says it is doing, in a full sentence.
  let status: String
  let image: PanelImageSource?
  let account: String
  let phase: WorkshopDownloader.Phase?
  let progress: Double?
  /// Waiting for a slot, or holding one.
  let isPending: Bool
  let isQueued: Bool
  let isPaused: Bool
  let isCancelled: Bool
  /// The sign-in that downloads nothing.
  let isSignInOnly: Bool
  /// Signed in, but Steam has not asked for anything yet: the dialog must stay open through it.
  let isAuthenticating: Bool
  let bytesReceived: Int64?
  let bytesExpected: Int64?
  let bytesPerSecond: Double?
  let secondsRemaining: Int?
  let errorMessage: String?
  let prompt: WorkshopDownloader.Prompt?
  let challenge: WorkshopDownloader.SteamGuardChallenge?
  let warning: String?
  let ownership: WorkshopDownloader.WallpaperEngineOwnership
  /// **Download and apply** is pending for this item.
  let appliesOnArrival: Bool

  /// Holding a slot: transferring, signing in or installing.
  var isRunning: Bool { isPending && !isQueued }
  /// A running job that waits for the user's password or Steam Guard answer.
  var needsAuthentication: Bool { isRunning && (prompt != nil || challenge != nil) }
  var hasError: Bool { !(errorMessage ?? "").isEmpty }
  /// Unfinished business the queue keeps in sight with its recovery action: a failure, a
  /// cancellation or a pause.
  var needsReview: Bool { hasError || isCancelled || isPaused }
  /// Over, but not finished well: the Downloads list keeps it visible with its recovery.
  var isUnresolved: Bool { !isPending && needsReview }

  // What the Downloads list offers for the row.

  /// A job that is running or waiting can be paused, except the sign-in, which downloads nothing.
  var canPause: Bool { isPending && !isPaused && !isSignInOnly }
  /// Anything under way or paused can be cancelled; a waiting job is removed from the queue.
  var canCancel: Bool { isPending || isPaused }
  var canResume: Bool { isPaused && !isPending }
  /// A failed or cancelled job can be tried again.
  var canRetry: Bool { isUnresolved && !isPaused }
  /// Whether Steam or pixiv needs the user, or the job failed: what marks the Downloads button.
  var needsAttention: Bool { prompt != nil || challenge != nil || hasError }
  /// The answer to what Steam asked for is a secret.
  var promptIsSecret: Bool { prompt == .password }

  /// The fraction downloaded, kept to 0...1, or nil when the job has no figure.
  var clampedProgress: Double? {
    guard let progress, progress.isFinite else { return nil }
    return min(max(progress, 0), 1)
  }

  init(
    id: String, source: Source = .steam, wallpaperID: String? = nil, title: String,
    status: String = "", image: PanelImageSource? = nil, account: String = "",
    phase: WorkshopDownloader.Phase? = nil, progress: Double? = nil, isPending: Bool = false,
    isQueued: Bool = false, isPaused: Bool = false, isCancelled: Bool = false,
    isSignInOnly: Bool = false, isAuthenticating: Bool = false, bytesReceived: Int64? = nil,
    bytesExpected: Int64? = nil, bytesPerSecond: Double? = nil, secondsRemaining: Int? = nil,
    errorMessage: String? = nil, prompt: WorkshopDownloader.Prompt? = nil,
    challenge: WorkshopDownloader.SteamGuardChallenge? = nil, warning: String? = nil,
    ownership: WorkshopDownloader.WallpaperEngineOwnership = .unknown,
    appliesOnArrival: Bool = false
  ) {
    self.id = id
    self.source = source
    self.wallpaperID = wallpaperID
    self.title = title
    self.status = status
    self.image = image
    self.account = account
    self.phase = phase
    self.progress = progress
    self.isPending = isPending
    self.isQueued = isQueued
    self.isPaused = isPaused
    self.isCancelled = isCancelled
    self.isSignInOnly = isSignInOnly
    self.isAuthenticating = isAuthenticating
    self.bytesReceived = bytesReceived
    self.bytesExpected = bytesExpected
    self.bytesPerSecond = bytesPerSecond
    self.secondsRemaining = secondsRemaining
    self.errorMessage = errorMessage
    self.prompt = prompt
    self.challenge = challenge
    self.warning = warning
    self.ownership = ownership
    self.appliesOnArrival = appliesOnArrival
  }

  /// How Steam's job reads.
  @MainActor
  init(_ job: WorkshopDownload, appliesOnArrival: Bool) {
    let worker = job.worker
    self.init(
      id: job.id, wallpaperID: job.item?.id,
      title: job.item?.title ?? WorkshopDownloadStage.itemlessTitle(id: job.id), status: job.status,
      image: job.item?.thumbnail, account: job.account, phase: job.phase, progress: job.progress,
      isPending: job.isPending, isQueued: job.isQueued, isPaused: job.isPaused,
      isCancelled: job.isCancelled, isSignInOnly: job.isSignIn,
      isAuthenticating: job.isPending && !job.isQueued && worker.isAuthenticating,
      bytesReceived: job.bytesReceived, bytesExpected: job.bytesExpected,
      bytesPerSecond: job.bytesPerSecond, secondsRemaining: job.secondsRemaining,
      errorMessage: job.errorMessage, prompt: worker.prompt, challenge: worker.steamGuardChallenge,
      warning: worker.sessionWarning, ownership: worker.wallpaperEngineOwnership,
      appliesOnArrival: appliesOnArrival)
  }

  /// How a pixiv save reads in the shared queue.
  @MainActor
  init(_ download: PixivDownloadRow) {
    self.init(
      id: download.id, source: .pixiv, wallpaperID: download.id, title: download.title,
      status: download.queueStatus, image: download.work.thumbnail, progress: download.progress,
      isPending: download.isPending, isQueued: download.status == .waiting,
      isPaused: download.status == .paused, isCancelled: download.status == .cancelled,
      bytesReceived: download.bytesReceived, bytesExpected: download.bytesExpected,
      errorMessage: download.errorMessage)
  }

  /// The amounts a transfer line words.
  var transferProgress: TransferFormat.Progress {
    TransferFormat.Progress(
      progress: progress, bytesReceived: bytesReceived.map(Double.init),
      bytesExpected: bytesExpected.map(Double.init), bytesPerSecond: bytesPerSecond,
      secondsRemaining: secondsRemaining.map(Double.init))
  }
}
