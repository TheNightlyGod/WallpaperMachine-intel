import Foundation

/// What Steam is asking one job for, as the download dialog tells requests apart: the job and the
/// password or challenge. A person who chooses **Not now** silences exactly this request, until
/// Steam asks for something else.
struct SteamAuthKey: Hashable {
  let jobID: String
  /// The prompt's or the challenge's name; empty while Steam has asked for nothing yet.
  let request: String

  init(_ job: DownloadRow) {
    jobID = job.id
    if let prompt = job.prompt {
      request = prompt.rawValue
    } else if let challenge = job.challenge {
      request = String(describing: challenge)
    } else {
      request = ""
    }
  }

  /// The keys of every pending job that asks for the user now. Closing the dialog silences them
  /// all, not only the one it was opened for.
  static func askingNow(in jobs: [DownloadRow]) -> Set<SteamAuthKey> {
    Set(jobs.filter { $0.isPending && ($0.prompt != nil || $0.challenge != nil) }.map(Self.init))
  }

  /// The job whose password or Steam Guard request should open the dialog by itself, or nil. A
  /// password or a code is the one thing a download cannot finish alone, so it surfaces on its own;
  /// a saved sign-in never asks, so routine downloads stay on their tile. A request already
  /// dismissed stays quiet, and so does the sign-in-only job while the first-run guide is open: the
  /// guide answers its prompts itself.
  static func surfaced(
    in jobs: [DownloadRow], dismissed: Set<SteamAuthKey>, welcomeIsOpen: Bool
  ) -> DownloadRow? {
    let asking = jobs.first {
      $0.isRunning && ($0.prompt != nil || $0.challenge != nil)
        && !($0.isSignInOnly && welcomeIsOpen)
    }
    guard let asking, !dismissed.contains(SteamAuthKey(asking)) else { return nil }
    return asking
  }
}

/// Which stage the download dialog is at for the item it was opened on, and what it says there.
///
/// The dialog opens only on an explicit request, and while it is open every change of the request
/// and the jobs is re-resolved: a retained request shows its missing prerequisite (setup, account or
/// consent); a job that is signing in shows its prompt and stays open through the connecting step;
/// and the moment the sign-in completes it says so, with live progress, rather than closing
/// mid-thought. It follows the shared-resources job's sign-in when the item waits behind that job.
/// Anything else closes it. A view calls `resolve` whenever the request or a job changes.
struct DownloadDialogResolution: Equatable {
  enum Stage: Equatable {
    case setup, account, resources
    /// Steam is signing a job in: connecting, a password, a Steam Guard request.
    case auth
    /// Signed in and under way: the hand-off card, which the dialog closes after a few seconds.
    case started

    /// The prerequisite stage of a retained request; nil for a request that has none left.
    fileprivate init?(prerequisite stage: WorkshopDownloadStage) {
      switch stage {
      case .setup: self = .setup
      case .account: self = .account
      case .resources: self = .resources
      case .ready: return nil
      }
    }
  }

  /// How long the hand-off card stays before the dialog closes itself.
  static let handoffDuration: Duration = .seconds(6)

  let stage: Stage
  /// The retained request, while the dialog waits for one of its prerequisites.
  let request: DownloadRequestRow?
  /// The job whose sign-in the dialog follows (`.auth`), or that has just taken over (`.started`).
  let job: DownloadRow?
  /// The dialog is about this title and image: the request, the job itself or the job it follows.
  let subjectID: String
  let subjectTitle: String
  let subjectImage: PanelImageSource?
  /// The dialog reaches the hand-off card for this item for the first time, which starts the
  /// timer that closes it.
  let beginsHandoff: Bool

  /// The heading's text.
  @MainActor
  var title: String {
    switch stage {
    case .setup, .account, .resources:
      request?.stage.dialogTitle ?? WorkshopDownloadStage.ready.dialogTitle
    case .auth:
      job?.challenge != nil
        ? L("Verify this Steam sign-in")
        : job?.prompt != nil ? L("Sign in to Steam") : L("Connecting to Steam")
    case .started: L("Signed in to Steam")
    }
  }

  /// The line under the heading: the job being signed in when it is not the item itself (the
  /// shared-resources job), else the item's title.
  @MainActor
  var subtitle: String {
    guard stage == .auth || stage == .started, let job, job.id != subjectID else { return subjectTitle }
    return L("\(job.title) · needed for \(subjectTitle)")
  }

  /// The picture beside the heading: the job's own at the sign-in, else the subject's.
  var image: PanelImageSource? {
    stage == .auth ? job?.image ?? subjectImage : subjectImage
  }

  /// Resolves the dialog open on `target`, or returns nil when it has nothing left to say and
  /// closes.
  ///
  /// - Parameters:
  ///   - request: the retained request for `target`, if any.
  ///   - own: the job for `target`, if any.
  ///   - sceneAssets: the shared scene-assets job, which an item waiting behind it follows.
  ///   - currentStage: the stage the dialog is showing now; nil when it is not open.
  ///   - handoffTarget: the item whose hand-off card has already been shown, if any.
  static func resolve(
    target: String, request: DownloadRequestRow?, own: DownloadRow?, sceneAssets: DownloadRow?,
    currentStage: Stage?, handoffTarget: String?
  ) -> DownloadDialogResolution? {
    func pendingAuth(_ job: DownloadRow?) -> DownloadRow? {
      guard let job, job.isRunning,
        job.isAuthenticating || job.prompt != nil || job.challenge != nil
      else { return nil }
      return job
    }
    func running(_ job: DownloadRow?) -> DownloadRow? {
      guard let job, job.isPending, !job.hasError, pendingAuth(job) == nil else { return nil }
      return job
    }

    let auth =
      pendingAuth(own)
      ?? (request != nil || own?.isQueued == true ? pendingAuth(sceneAssets) : nil)
    let waitingStage = request.flatMap { Stage(prerequisite: $0.stage) }
    let waiting = waitingStage == nil ? nil : request
    // The moment a sign-in completes the transfer is already running: say so, instead of closing.
    var started: DownloadRow?
    if waiting == nil, auth == nil, currentStage == .auth || handoffTarget == target {
      started = (own?.isQueued == true ? running(sceneAssets) : nil) ?? running(own)
    }
    guard waiting != nil || auth != nil || started != nil else { return nil }

    // What the dialog is about: the request waiting, else the job itself, else the job it follows.
    let followed = auth ?? started
    let subject: (title: String, image: PanelImageSource?) =
      waiting.map { ($0.title, $0.image) } ?? own.map { ($0.title, $0.image) }
      ?? followed.map { ($0.title, $0.image) } ?? ("", nil)
    return DownloadDialogResolution(
      stage: waitingStage ?? (started != nil ? .started : .auth), request: waiting, job: followed,
      subjectID: target, subjectTitle: subject.title, subjectImage: subject.image,
      beginsHandoff: started != nil && handoffTarget != target)
  }
}
