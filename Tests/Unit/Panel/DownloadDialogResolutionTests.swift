import XCTest

@testable import WallpaperMachine

/// Which stage the download dialog is at for the item it is open on, and when it closes: the rules
/// that keep a dialog the user opened from vanishing mid-thought, and from reopening on its own.
@MainActor
final class DownloadDialogResolutionTests: MediaPanelTestCase {
  private let assets = WorkshopStore.sceneAssetsRequestID

  private func resolve(
    request: DownloadRequestRow? = nil, own: DownloadRow? = nil, sceneAssets: DownloadRow? = nil,
    current: DownloadDialogResolution.Stage? = nil, handoff: String? = nil
  ) -> DownloadDialogResolution? {
    DownloadDialogResolution.resolve(
      target: "222", request: request, own: own, sceneAssets: sceneAssets, currentStage: current,
      handoffTarget: handoff)
  }

  private func request(_ stage: WorkshopDownloadStage) -> DownloadRequestRow {
    DownloadRequestRow(id: "222", title: "Local video", stage: stage)
  }

  private func job(
    pending: Bool = true, queued: Bool = false, authenticating: Bool = false,
    prompt: WorkshopDownloader.Prompt? = nil, challenge: WorkshopDownloader.SteamGuardChallenge? = nil,
    error: String? = nil, id: String = "222", title: String = "Local video"
  ) -> DownloadRow {
    DownloadRow(
      id: id, title: title, isPending: pending, isQueued: queued, isAuthenticating: authenticating,
      errorMessage: error, prompt: prompt, challenge: challenge)
  }

  func testARetainedRequestShowsItsMissingPrerequisite() throws {
    for (stage, expected) in [
      (WorkshopDownloadStage.setup, DownloadDialogResolution.Stage.setup),
      (.account, .account), (.resources, .resources),
    ] {
      let resolution = try XCTUnwrap(resolve(request: request(stage)))
      XCTAssertEqual(resolution.stage, expected)
      XCTAssertEqual(resolution.request?.id, "222")
      XCTAssertEqual(resolution.subjectTitle, "Local video")
      XCTAssertEqual(resolution.subtitle, "Local video")
      XCTAssertFalse(resolution.beginsHandoff)
    }
    XCTAssertEqual(try XCTUnwrap(resolve(request: request(.setup))).title, "Install SteamCMD")
    XCTAssertEqual(try XCTUnwrap(resolve(request: request(.account))).title, "Sign in to Steam")
    XCTAssertEqual(try XCTUnwrap(resolve(request: request(.resources))).title, "Shared resources needed")
  }

  func testARequestWithNothingLeftToWaitForAndNoJobClosesTheDialog() {
    XCTAssertNil(resolve(request: request(.ready)))
    XCTAssertNil(resolve())
    XCTAssertNil(resolve(own: job(pending: false)), "a finished job has nothing to say")
  }

  func testASigningInJobKeepsTheDialogOpenThroughTheConnectingStepAndItsPrompts() throws {
    let connecting = try XCTUnwrap(resolve(own: job(authenticating: true)))
    XCTAssertEqual(connecting.stage, .auth)
    XCTAssertEqual(connecting.title, "Connecting to Steam", "no prompt yet")
    let password = try XCTUnwrap(resolve(own: job(prompt: .password)))
    XCTAssertEqual(password.title, "Sign in to Steam")
    let challenge = try XCTUnwrap(resolve(own: job(challenge: .mobileApproval)))
    XCTAssertEqual(challenge.title, "Verify this Steam sign-in")
    XCTAssertEqual(challenge.job?.challenge, .mobileApproval)
  }

  func testAQueuedJobWaitsBehindTheSharedAssetsJobAndFollowsItsSignIn() throws {
    let waiting = job(queued: true)
    let signingIn = job(prompt: .password, id: assets, title: "Scene assets")
    let followed = try XCTUnwrap(resolve(own: waiting, sceneAssets: signingIn))
    XCTAssertEqual(followed.stage, .auth)
    XCTAssertEqual(followed.job?.id, assets)
    XCTAssertEqual(followed.subjectTitle, "Local video")
    XCTAssertEqual(followed.subtitle, "Scene assets · needed for Local video")

    // The same job the request waits on, with no job of its own yet.
    let withRequest = try XCTUnwrap(resolve(request: request(.ready), sceneAssets: signingIn))
    XCTAssertEqual(withRequest.stage, .auth)
    XCTAssertNil(resolve(own: job(pending: false), sceneAssets: signingIn), "nothing waits behind it")
  }

  func testWhenTheSignInCompletesTheDialogSaysSoInsteadOfClosingAndTheHandoffStartsOnce() throws {
    let transferring = job()
    XCTAssertNil(
      resolve(own: transferring), "a download that never asked for anything shows no dialog by itself")
    let started = try XCTUnwrap(resolve(own: transferring, current: .auth))
    XCTAssertEqual(started.stage, .started)
    XCTAssertEqual(started.title, "Signed in to Steam")
    XCTAssertTrue(started.beginsHandoff, "the first time the card shows, its timer starts")

    let later = try XCTUnwrap(resolve(own: transferring, current: .started, handoff: "222"))
    XCTAssertEqual(later.stage, .started, "later progress updates keep the card up")
    XCTAssertFalse(later.beginsHandoff)
    XCTAssertEqual(DownloadDialogResolution.handoffDuration, .seconds(6))
  }

  func testAFailedJobDoesNotCountAsStartedAndTheSharedAssetsJobCanCarryTheHandoff() throws {
    XCTAssertNil(resolve(own: job(error: "Steam denied this download."), current: .auth))
    let waiting = job(queued: true)
    let sharedRunning = job(id: assets, title: "Scene assets")
    let started = try XCTUnwrap(resolve(own: waiting, sceneAssets: sharedRunning, current: .auth))
    XCTAssertEqual(started.stage, .started)
    XCTAssertEqual(started.job?.id, assets)
    XCTAssertEqual(started.subtitle, "Scene assets · needed for Local video")
  }

  func testAPrerequisiteStageWinsOverEverythingElse() throws {
    let resolution = try XCTUnwrap(
      resolve(request: request(.account), own: job(prompt: .password), current: .auth))
    XCTAssertEqual(resolution.stage, .account)
  }

  // MARK: Auth requests

  func testNotNowSilencesExactlyThatRequestUntilSteamAsksForSomethingElse() {
    let password = job(prompt: .password)
    let dismissed = SteamAuthKey.askingNow(in: [password])
    XCTAssertEqual(dismissed.count, 1)
    XCTAssertNil(SteamAuthKey.surfaced(in: [password], dismissed: dismissed, welcomeIsOpen: false))
    let code = job(challenge: .mobileApproval)
    XCTAssertEqual(
      SteamAuthKey.surfaced(in: [code], dismissed: dismissed, welcomeIsOpen: false)?.id, "222",
      "a new request for the same job is a new key")
  }

  func testClosingTheDialogSilencesEveryJobThatIsAskingNowQueuedOnesIncluded() {
    let queuedAsking = DownloadRow(id: "q", title: "Q", isPending: true, isQueued: true, prompt: .guardCode)
    let running = job(prompt: .password)
    let idle = DownloadRow(id: "i", title: "I", isPending: true)
    let finished = DownloadRow(id: "f", title: "F", prompt: .password)
    let keys = SteamAuthKey.askingNow(in: [queuedAsking, running, idle, finished])
    XCTAssertEqual(Set(keys.map(\.jobID)), ["q", "222"])
  }

  func testOnlyARunningJobThatAsksSurfacesAndTheWelcomeKeepsItsOwnSignIn() {
    let queuedAsking = DownloadRow(id: "q", title: "Q", isPending: true, isQueued: true, prompt: .password)
    XCTAssertNil(SteamAuthKey.surfaced(in: [queuedAsking], dismissed: [], welcomeIsOpen: false))
    let signIn = DownloadRow(
      id: WorkshopStore.signInRequestID, title: "Steam sign-in", isPending: true, isSignInOnly: true,
      prompt: .password)
    XCTAssertNil(SteamAuthKey.surfaced(in: [signIn], dismissed: [], welcomeIsOpen: true))
    XCTAssertEqual(
      SteamAuthKey.surfaced(in: [signIn], dismissed: [], welcomeIsOpen: false)?.id,
      WorkshopStore.signInRequestID)
    let other = job(prompt: .guardCode)
    XCTAssertEqual(
      SteamAuthKey.surfaced(in: [signIn, other], dismissed: [], welcomeIsOpen: true)?.id, "222",
      "the guide skips only its own job")
  }

  func testTheGuideFollowsTheChallengeAndAPasswordNeedsNoGuide() {
    XCTAssertEqual(SteamGuardGuide.guide(for: job(challenge: .mobileApproval)), .mobileApproval)
    XCTAssertEqual(SteamGuardGuide.guide(for: job(challenge: .authenticatorCode)), .authenticatorCode)
    XCTAssertEqual(SteamGuardGuide.guide(for: job(challenge: .emailCode)), .emailCode)
    XCTAssertNil(SteamGuardGuide.guide(for: job(prompt: .password)))
    XCTAssertEqual(SteamGuardGuide.guide(for: job(prompt: .guardCode)), .unknown)
    XCTAssertNil(SteamGuardGuide.guide(for: job(authenticating: true)))
  }

  func testEachGuideListsItsStepsAndMobileApprovalAsksForNothingToType() {
    let approval = SteamGuardGuide.mobileApproval
    XCTAssertGreaterThanOrEqual(approval.steps(account: "fixture").count, 3)
    XCTAssertFalse(approval.asksForInput)
    XCTAssertTrue(SteamGuardGuide.authenticatorCode.asksForInput)
    XCTAssertEqual(SteamGuardGuide.emailCode.help, .emailedCodes)
    XCTAssertEqual(SteamGuardGuide.emailCode.help.url, ExternalLink.steamEmailedCodeHelp)
    for phone in [SteamGuardGuide.mobileApproval, .authenticatorCode, .unknown] {
      XCTAssertEqual(phone.help.url, ExternalLink.steamMobileApp)
      XCTAssertTrue(ExternalLink.isAllowed(phone.help.url))
    }
    XCTAssertNil(SteamGuardGuide.unknown.note)
    XCTAssertNotNil(SteamGuardGuide.emailCode.note)
  }

  func testTheAccountAndTheCuesAreBoldInTheMobileApprovalSteps() throws {
    let steps = SteamGuardGuide.mobileApproval.steps(account: "fixture")
    let second = try XCTUnwrap(steps.dropFirst().first)
    let bold = second.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }
    XCTAssertEqual(bold.map { String(second[$0.range].characters) }, ["fixture"])
    let unnamed = SteamGuardGuide.mobileApproval.steps(account: "")
    XCTAssertTrue(String(unnamed[1].characters).contains("your account"))
  }
}
