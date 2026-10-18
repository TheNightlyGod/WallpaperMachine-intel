import Foundation

/// Where the Steam page of the guide stands: which of its states it shows, worked out from the
/// sign-in job (the sign-in-only session the guide starts), the retained request that waits for a
/// prerequisite, and the account saved on this Mac. Plain values, so the whole decision table is
/// tested without a window.
struct SteamSignInPhase: Equatable {
  /// What the signing-in card shows while the job runs, in the order the checks are made.
  enum SigningIn: Equatable {
    /// Signed in; Steam is being asked whether the account owns Wallpaper Engine.
    case checkingOwnership
    /// Waiting for a download slot or for another sign-in.
    case queued(status: String)
    /// Steam asks for something typed: the password, or a Steam Guard code. `guide` is the card that
    /// explains a code; a plain password prompt needs none.
    case prompt(DownloadRow, guide: SteamGuardGuide?)
    /// Steam waits for approval on the phone and asks for nothing typed.
    case challenge(SteamGuardGuide)
    /// Connecting.
    case authenticating(status: String)
  }

  enum State: Equatable {
    /// An account is signed in; `ownership` says what Wallpaper Engine's license check found.
    case signedIn(account: String, ownership: WorkshopDownloader.WallpaperEngineOwnership, warning: String?)
    /// The retained sign-in request waits for SteamCMD.
    case setup(DownloadRequestRow)
    /// The sign-in form, with why the last attempt failed.
    case form(jobFailure: JobFailure?)
    case signingIn(SigningIn)
  }

  enum JobFailure: Equatable {
    case message(String)
    case cancelled
  }

  let state: State
  /// A retained request or a pending job exists: the guide is waiting on Steam.
  let isInProgress: Bool

  /// - Parameters:
  ///   - job: the sign-in job, which stays in the downloads list after it finishes.
  ///   - request: the retained sign-in request, present while a prerequisite is missing.
  ///   - savedAccount: the account whose sign-in is saved on this Mac.
  ///   - dismissedJob: the person chose **Use a different account**, so a finished job no longer
  ///     counts.
  static func resolve(
    job: DownloadRow?, request: DownloadRequestRow?, savedAccount: String?, dismissedJob: Bool
  ) -> SteamSignInPhase {
    let inProgress = request != nil || job?.isPending == true
    let account = resolvedAccount(
      job: job, request: request, savedAccount: savedAccount, dismissedJob: dismissedJob)
    if !account.isEmpty {
      // The ownership a job found is only trusted for the job of the account that is shown.
      let trusted = !dismissedJob && job?.account == account
      return SteamSignInPhase(
        state: .signedIn(
          account: account, ownership: trusted ? job?.ownership ?? .unknown : .unknown,
          warning: trusted ? job?.warning.flatMap { $0.isEmpty ? nil : $0 } : nil),
        isInProgress: inProgress)
    }
    if let request {
      return SteamSignInPhase(
        state: request.stage == .setup ? .setup(request) : .form(jobFailure: nil),
        isInProgress: inProgress)
    }
    if let job, job.isPending {
      return SteamSignInPhase(state: .signingIn(signingIn(job)), isInProgress: true)
    }
    return SteamSignInPhase(state: .form(jobFailure: failure(of: job)), isInProgress: false)
  }

  /// The account that counts as signed in: none while a sign-in is in progress; else the finished
  /// job's account when it succeeded; once the person signed out (or when there is no job), the
  /// account saved on this Mac. Empty means not signed in.
  static func resolvedAccount(
    job: DownloadRow?, request: DownloadRequestRow?, savedAccount: String?, dismissedJob: Bool
  ) -> String {
    if job?.isPending == true || request != nil { return "" }
    if let job, !dismissedJob { return job.hasError || job.isCancelled ? "" : job.account }
    return savedAccount ?? ""
  }

  private static func signingIn(_ job: DownloadRow) -> SigningIn {
    if !job.isQueued && !job.isAuthenticating && job.prompt == nil && job.challenge == nil {
      return .checkingOwnership
    }
    if job.isQueued { return .queued(status: job.status) }
    if job.prompt != nil { return .prompt(job, guide: SteamGuardGuide.guide(for: job)) }
    if let guide = SteamGuardGuide.guide(for: job) { return .challenge(guide) }
    return .authenticating(status: job.status)
  }

  private static func failure(of job: DownloadRow?) -> JobFailure? {
    guard let job else { return nil }
    if let message = job.errorMessage, !message.isEmpty { return .message(message) }
    return job.isCancelled ? .cancelled : nil
  }

  /// The account that is signed in, or empty.
  var signedInAccount: String {
    if case .signedIn(let account, _, _) = state { return account }
    return ""
  }

  var isSignedIn: Bool { !signedInAccount.isEmpty }

  /// The ownership notice of a signed-in account.
  var ownership: WorkshopDownloader.WallpaperEngineOwnership? {
    if case .signedIn(_, let ownership, _) = state { return ownership }
    return nil
  }

  var showsForm: Bool {
    if case .form = state { return true }
    return false
  }

  /// The title of the status card the page shows for this state, in the words the card uses: what
  /// VoiceOver announces when it changes, as the page's live status. Nil for the form, whose
  /// failures announce themselves.
  ///
  /// - Parameter setupStatus: SteamCMD's state, the title of the setup card.
  @MainActor
  func statusTitle(setupStatus: String) -> String? {
    switch state {
    case .signedIn(let account, _, _): L("Signed in as \(account)")
    case .setup: setupStatus
    case .form: nil
    case .signingIn(.checkingOwnership): L("Checking Wallpaper Engine ownership…")
    case .signingIn(.queued(let status)): status
    case .signingIn(.prompt(_, let guide)): guide?.title ?? L("Steam asks for your password")
    case .signingIn(.challenge(let guide)): guide.title
    case .signingIn(.authenticating(let status)): status.isEmpty ? L("Contacting Steam…") : status
    }
  }

  /// Steam needs the person and the guide is not on the Steam page: the step dot says so. A password
  /// the guide holds and is about to answer, or an answer already on its way, needs nobody.
  static func needsAttention(
    job: DownloadRow?, answerInFlight: Bool, holdsSecret: Bool
  ) -> Bool {
    guard let job, job.isPending, !job.isQueued, job.prompt != nil || job.challenge != nil
    else { return false }
    return !answerInFlight && !(job.promptIsSecret && holdsSecret)
  }
}

/// What the ownership check found, as the signed-in card words it and what it offers.
struct OwnershipNotice: Equatable {
  let ownership: WorkshopDownloader.WallpaperEngineOwnership

  /// A confirmed owner gets the success look; everything else is information.
  var isSuccess: Bool { ownership == .owned }
  /// Only a confirmed non-owner is offered the store page.
  var offersPurchase: Bool { ownership == .notOwned }
  /// An owner has nothing to check again.
  var offersRecheck: Bool { ownership != .owned }
  var symbol: String { isSuccess ? "checkmark" : "info" }

  @MainActor
  var message: String {
    switch ownership {
    case .owned:
      L("Wallpaper Engine ownership confirmed. You can download its Workshop wallpapers.")
    case .notOwned:
      L(
        "This Steam account does not own Wallpaper Engine. Please purchase it on Steam to download Wallpaper Engine wallpapers. You can still download from Pixiv, browse the Workshop, and view Wallpaper Engine wallpapers you already have."
      )
    case .unknown:
      L(
        "Wallpaper Engine ownership has not been confirmed. Check again to verify this account can download its Workshop wallpapers. You can still download from Pixiv, browse the Workshop, and view wallpapers you already have."
      )
    }
  }
}

/// Where keyboard or VoiceOver focus goes when the Steam page changes under the person.
enum SteamFocusTarget: Equatable {
  /// The Steam Guard code or password field Steam asks about.
  case response
  /// The password field, after a failed attempt.
  case password
  /// The footer's Continue button, once signed in.
  case continueButton
  /// The page title, while the guide waits on Steam.
  case title

  /// The target for the page's state, or nil when nothing needs the person's attention. The guide
  /// applies it only when focus has nowhere to be (it was lost with a view that went away), never
  /// over something the person focused.
  static func resolve(
    job: DownloadRow?, hasRequest: Bool, isSignedIn: Bool, showsForm: Bool, hasPageError: Bool
  ) -> SteamFocusTarget? {
    if let job, job.isRunning, job.prompt != nil { return .response }
    if (job?.hasError == true || hasPageError) && showsForm { return .password }
    if isSignedIn { return .continueButton }
    if hasRequest || job?.isPending == true { return .title }
    return nil
  }

  /// Everything the target depends on, so a view re-evaluates it exactly when one of them moves.
  struct Key: Equatable {
    var stage: WorkshopDownloadStage?
    var isPending: Bool
    var isQueued: Bool
    var prompt: WorkshopDownloader.Prompt?
    var hasChallenge: Bool
    var signedInAccount: String
    var hasJobError: Bool
    var isCancelled: Bool
    var pageError: String?

    init(job: DownloadRow?, request: DownloadRequestRow?, signedInAccount: String, pageError: String?) {
      stage = request?.stage
      isPending = job?.isPending ?? false
      isQueued = job?.isQueued ?? false
      prompt = job?.prompt
      hasChallenge = job?.challenge != nil
      self.signedInAccount = signedInAccount
      hasJobError = job?.hasError ?? false
      isCancelled = job?.isCancelled ?? false
      self.pageError = pageError
    }
  }
}
