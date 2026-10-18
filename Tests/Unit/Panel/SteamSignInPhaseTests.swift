import XCTest

@testable import WallpaperMachine

/// Which state the guide's Steam page shows, worked out from the sign-in job, the retained request
/// and the saved account; the ownership notice; the attention marker; and where focus goes when
/// the page changes under the person. Ports the guide's `signedIn()` table and focus rules.
@MainActor
final class SteamSignInPhaseTests: XCTestCase {
  private func job(
    account: String = "localtest", pending: Bool = false, queued: Bool = false,
    authenticating: Bool = false, prompt: WorkshopDownloader.Prompt? = nil,
    challenge: WorkshopDownloader.SteamGuardChallenge? = nil, error: String? = nil,
    cancelled: Bool = false, ownership: WorkshopDownloader.WallpaperEngineOwnership = .unknown,
    status: String = "", warning: String? = nil
  ) -> DownloadRow {
    DownloadRow(
      id: WorkshopStore.signInRequestID, title: "Steam sign-in", status: status, account: account,
      isPending: pending, isQueued: queued, isCancelled: cancelled, isSignInOnly: true,
      isAuthenticating: authenticating, errorMessage: error, prompt: prompt, challenge: challenge,
      warning: warning, ownership: ownership)
  }

  private func request(_ stage: WorkshopDownloadStage) -> DownloadRequestRow {
    DownloadRequestRow(id: WorkshopStore.signInRequestID, title: "Steam sign-in", stage: stage)
  }

  private func resolve(
    job: DownloadRow? = nil, request: DownloadRequestRow? = nil, saved: String? = nil,
    dismissed: Bool = false
  ) -> SteamSignInPhase {
    SteamSignInPhase.resolve(job: job, request: request, savedAccount: saved, dismissedJob: dismissed)
  }

  // MARK: Signed in

  /// While a sign-in is in progress nobody is signed in; a finished job decides by how it ended; with
  /// no job (or after signing out) the saved account counts.
  func testWhoIsSignedInFollowsTheJobThenTheSavedAccount() {
    let signedIn = SteamSignInPhase.resolvedAccount
    XCTAssertEqual(signedIn(job(pending: true), nil, "saved", false), "", "In progress")
    XCTAssertEqual(signedIn(nil, request(.setup), "saved", false), "", "A request waits")
    XCTAssertEqual(signedIn(job(), nil, "saved", false), "localtest", "A finished job decides")
    XCTAssertEqual(signedIn(job(error: "No"), nil, "saved", false), "", "A failed one is not signed in")
    XCTAssertEqual(signedIn(job(cancelled: true), nil, "saved", false), "")
    XCTAssertEqual(signedIn(nil, nil, "saved", false), "saved", "No job: the saved account")
    XCTAssertEqual(signedIn(nil, nil, nil, false), "")
    XCTAssertEqual(signedIn(job(), nil, "saved", true), "saved", "Signed out: the job no longer counts")
    XCTAssertEqual(signedIn(job(), nil, nil, true), "")
  }

  func testSignedInShowsTheOwnershipOnlyOfTheJobOfThatAccount() {
    let fresh = resolve(job: job(ownership: .notOwned), saved: nil)
    XCTAssertEqual(fresh.ownership, .notOwned)
    XCTAssertEqual(fresh.signedInAccount, "localtest")

    let saved = resolve(job: nil, saved: "olduser")
    XCTAssertEqual(saved.ownership, .unknown, "A saved account from an earlier run is not confirmed")
    XCTAssertTrue(saved.isSignedIn)

    let afterSignOut = resolve(job: job(ownership: .owned), saved: "olduser", dismissed: true)
    XCTAssertEqual(afterSignOut.signedInAccount, "olduser")
    XCTAssertEqual(afterSignOut.ownership, .unknown, "A dismissed job's ownership is not trusted")
  }

  func testTheSessionWarningShowsOnTheSignedInCard() {
    let phase = resolve(job: job(warning: "Steam did not provide reusable sign-in files."))
    guard case .signedIn(_, _, let warning) = phase.state else { return XCTFail("Not signed in") }
    XCTAssertEqual(warning, "Steam did not provide reusable sign-in files.")
  }

  // MARK: Which state

  func testTheDecisionOrderFormSetupSigningIn() {
    XCTAssertEqual(resolve().state, .form(jobFailure: nil))
    XCTAssertFalse(resolve().isInProgress)

    XCTAssertEqual(resolve(request: request(.setup)).state, .setup(request(.setup)))
    XCTAssertEqual(
      resolve(request: request(.account)).state, .form(jobFailure: nil),
      "The downloader refused the name: the form returns")
    XCTAssertTrue(resolve(request: request(.account)).isInProgress)

    let running = resolve(job: job(pending: true))
    guard case .signingIn = running.state else { return XCTFail("Not signing in") }
    XCTAssertTrue(running.isInProgress)
  }

  func testAFailedOrCancelledJobReturnsTheFormWithTheReason() {
    XCTAssertEqual(
      resolve(job: job(error: "Wrong password")).state, .form(jobFailure: .message("Wrong password")))
    XCTAssertEqual(resolve(job: job(cancelled: true)).state, .form(jobFailure: .cancelled))
    XCTAssertEqual(resolve(job: job(error: "")).state, .signedIn(account: "localtest", ownership: .unknown, warning: nil))
  }

  // MARK: Signing in

  func testTheSigningInSubstatesAreCheckedInOrder() {
    func substate(_ row: DownloadRow) -> SteamSignInPhase.SigningIn? {
      if case .signingIn(let substate) = resolve(job: row).state { return substate }
      return nil
    }
    XCTAssertEqual(substate(job(pending: true)), .checkingOwnership)
    XCTAssertEqual(substate(job(pending: true, queued: true, status: "Waiting")), .queued(status: "Waiting"))
    XCTAssertEqual(
      substate(job(pending: true, authenticating: true, status: "Connecting")),
      .authenticating(status: "Connecting"))

    let password = job(pending: true, authenticating: true, prompt: .password)
    XCTAssertEqual(substate(password), .prompt(password, guide: nil), "A password needs no card")
    let code = job(pending: true, authenticating: true, prompt: .guardCode, challenge: .emailCode)
    XCTAssertEqual(substate(code), .prompt(code, guide: .emailCode))
    let bare = job(pending: true, authenticating: true, prompt: .guardCode)
    XCTAssertEqual(substate(bare), .prompt(bare, guide: .unknown), "A prompt Steam did not name")
    XCTAssertEqual(
      substate(job(pending: true, authenticating: true, challenge: .mobileApproval)),
      .challenge(.mobileApproval))
    XCTAssertEqual(
      substate(job(pending: true, queued: true, prompt: .password)), .queued(status: ""),
      "Queued comes before a prompt")
  }

  /// What VoiceOver hears when the page changes is the title of the card on show; the form has
  /// none of its own (its failures are announced by their notice).
  func testTheStatusIsTheTitleOfTheCardOnShow() {
    let setupStatus = "Downloading the tool"
    func status(_ row: DownloadRow? = nil, request: DownloadRequestRow? = nil) -> String? {
      resolve(job: row, request: request).statusTitle(setupStatus: setupStatus)
    }
    XCTAssertNil(status(), "The form")
    XCTAssertNil(status(job(error: "Wrong password")), "A failed attempt brings the form back")
    XCTAssertEqual(status(request: request(.setup)), setupStatus, "SteamCMD's own status")
    XCTAssertEqual(status(job()), L("Signed in as localtest"))
    XCTAssertEqual(status(job(pending: true)), L("Checking Wallpaper Engine ownership…"))
    XCTAssertEqual(status(job(pending: true, queued: true, status: "Waiting for a slot")), "Waiting for a slot")
    XCTAssertEqual(status(job(pending: true, authenticating: true)), L("Contacting Steam…"))
    XCTAssertEqual(status(job(pending: true, authenticating: true, status: "Logging in")), "Logging in")
    XCTAssertEqual(
      status(job(pending: true, authenticating: true, prompt: .password)), L("Steam asks for your password"))
    XCTAssertEqual(
      status(job(pending: true, authenticating: true, prompt: .guardCode, challenge: .emailCode)),
      SteamGuardGuide.emailCode.title)
    XCTAssertEqual(
      status(job(pending: true, authenticating: true, challenge: .mobileApproval)),
      SteamGuardGuide.mobileApproval.title)
  }

  /// The setup card's sentence matches what the card offers: an install in progress only while
  /// one runs, nothing beside a failure's own notice, and the two ways forward while nothing runs.
  func testTheSetupCardNeverClaimsAnInstallThatIsNotRunning() {
    typealias Detail = WelcomeSetupCard.Detail
    XCTAssertEqual(Detail.make(isBusy: true, canApprove: false, hasError: false), .installing)
    XCTAssertNil(Detail.make(isBusy: false, canApprove: false, hasError: true), "Setup failed")
    XCTAssertEqual(Detail.make(isBusy: false, canApprove: false, hasError: false), .installOrLocate)
    XCTAssertEqual(Detail.make(isBusy: false, canApprove: true, hasError: true), .approval)
  }

  // MARK: Ownership

  func testTheOwnershipNoticeOffersWhatEachFindingCalls() {
    let owned = OwnershipNotice(ownership: .owned)
    XCTAssertTrue(owned.isSuccess)
    XCTAssertFalse(owned.offersPurchase)
    XCTAssertFalse(owned.offersRecheck)
    XCTAssertEqual(owned.symbol, "checkmark")

    let missing = OwnershipNotice(ownership: .notOwned)
    XCTAssertFalse(missing.isSuccess)
    XCTAssertTrue(missing.offersPurchase)
    XCTAssertTrue(missing.offersRecheck)
    XCTAssertEqual(missing.symbol, "info")

    let unknown = OwnershipNotice(ownership: .unknown)
    XCTAssertFalse(unknown.offersPurchase, "Never a missing purchase on a guess")
    XCTAssertTrue(unknown.offersRecheck)
  }

  /// The words keep the alternatives open: Pixiv, browsing and what is already installed.
  func testBothUnfavourableNoticesNameWhatStillWorks() {
    for ownership in [WorkshopDownloader.WallpaperEngineOwnership.notOwned, .unknown] {
      let message = OwnershipNotice(ownership: ownership).message
      XCTAssertTrue(message.contains("Pixiv") || message.contains("pixiv"), "\(ownership): \(message)")
    }
  }

  // MARK: Attention

  func testSteamNeedsAttentionOnlyWhenItWaitsForAPersonWhoIsNotAnsweringIt() {
    let attention = SteamSignInPhase.needsAttention
    let guardCode = job(pending: true, authenticating: true, prompt: .guardCode, challenge: .emailCode)
    XCTAssertTrue(attention(guardCode, false, false))
    XCTAssertFalse(attention(guardCode, true, false), "An answer is on its way")
    XCTAssertFalse(attention(nil, false, false))
    XCTAssertFalse(attention(job(pending: true), false, false), "Nothing asked yet")
    XCTAssertFalse(attention(job(pending: true, queued: true, prompt: .password), false, false))
    XCTAssertFalse(attention(job(), false, false), "A finished job asks for nothing")

    let password = job(pending: true, authenticating: true, prompt: .password)
    XCTAssertTrue(attention(password, false, false), "A password nobody holds is the person's")
    XCTAssertFalse(attention(password, false, true), "A password the guide holds is answered by it")
    XCTAssertTrue(attention(guardCode, false, true), "A held password does not answer a code")
  }

  // MARK: Focus

  func testFocusGoesToTheFieldSteamAsksAboutThenTheFormThenContinueThenTheTitle() {
    let target = SteamFocusTarget.resolve
    let asking = job(pending: true, authenticating: true, prompt: .guardCode)
    XCTAssertEqual(
      target(asking, false, false, false, false), .response, "The response field when Steam asks")
    XCTAssertEqual(
      target(nil, false, false, true, true), .password, "The password after a failure on the form")
    XCTAssertEqual(target(job(error: "No"), false, false, true, false), .password)
    XCTAssertEqual(target(job(), false, true, false, false), .continueButton, "Continue once signed in")
    XCTAssertEqual(
      target(job(pending: true), false, false, false, false), .title, "The title while waiting")
    XCTAssertEqual(target(nil, true, false, false, false), .title, "A retained request waits too")
    XCTAssertNil(target(nil, false, false, true, false), "An idle form needs nothing")
    XCTAssertEqual(
      target(job(pending: true, queued: true, prompt: .password), false, false, false, false), .title,
      "A queued job asks nothing yet")
  }

  /// The key changes exactly when something the rule reads changes.
  func testTheFocusKeyMovesWithTheStateAndNotWithProgress() {
    let base = SteamFocusTarget.Key(job: job(pending: true), request: nil, signedInAccount: "", pageError: nil)
    XCTAssertEqual(
      base, SteamFocusTarget.Key(job: job(pending: true, status: "Another status"), request: nil, signedInAccount: "", pageError: nil))
    XCTAssertNotEqual(
      base,
      SteamFocusTarget.Key(job: job(pending: true, prompt: .password), request: nil, signedInAccount: "", pageError: nil))
    XCTAssertNotEqual(
      base, SteamFocusTarget.Key(job: job(pending: true), request: nil, signedInAccount: "", pageError: "Failed"))
    XCTAssertNotEqual(
      base, SteamFocusTarget.Key(job: job(pending: true), request: request(.setup), signedInAccount: "", pageError: nil))
  }

  // MARK: Recap

  func testTheRecapSaysWhereSteamStands() {
    let setupStatus = "Installing the tool"
    func steam(job: DownloadRow? = nil, request: DownloadRequestRow? = nil, saved: String? = nil) -> WelcomeRecap {
      WelcomeRecap.make(
        languageName: nil, appearance: .system,
        phase: resolve(job: job, request: request, saved: saved), job: job, request: request,
        setupStatus: setupStatus, unsavedPerformance: 0, unsavedPreferences: 0)
    }
    XCTAssertTrue(steam().steam.contains("first download"), "Not signed in: asked at the first download")
    XCTAssertFalse(steam().offersFinishingSignIn)
    XCTAssertTrue(steam(saved: "olduser").steam.contains("olduser"))
    XCTAssertEqual(steam(job: job(pending: true, status: "Contacting Steam…")).steam, "Contacting Steam…")
    XCTAssertTrue(steam(job: job(pending: true, status: "")).offersFinishingSignIn)
    XCTAssertEqual(steam(request: request(.account)).steam, WorkshopDownloadStage.account.hint)
    XCTAssertEqual(steam(request: request(.setup)).steam, setupStatus, "At the setup stage SteamCMD's own status")
    XCTAssertTrue(steam(request: request(.account)).offersFinishingSignIn)
  }

  func testTheRecapListsOnlyPagesWithUnsavedDrafts() {
    func recap(_ performance: Int, _ preferences: Int) -> WelcomeRecap {
      WelcomeRecap.make(
        languageName: "English", appearance: .dark, phase: resolve(), job: nil, request: nil,
        setupStatus: "", unsavedPerformance: performance, unsavedPreferences: preferences)
    }
    XCTAssertTrue(recap(0, 0).unsaved.isEmpty)
    XCTAssertEqual(recap(2, 0).unsaved.map(\.step), [.performance])
    XCTAssertEqual(recap(0, 1).unsaved.map(\.step), [.preferences])
    XCTAssertEqual(recap(1, 3).unsaved.map(\.count), [1, 3])
  }
}
