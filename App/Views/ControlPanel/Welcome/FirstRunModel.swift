import Foundation
import Observation

/// The first-run guide: six pages, shown once per Mac and again on request from Settings.
///
/// Language, appearance, the lock screen and the Steam sign-in act the moment they are chosen (Skip
/// puts back what was there when the guide opened); the performance choices and the other
/// preferences are drafts that **Continue** commits. The Steam page runs a sign-in-only SteamCMD
/// session through the downloads pipeline, so Steam's own password and Steam Guard prompts are
/// answered here. The password goes from the field to Steam's prompt and nowhere else: this model
/// keeps it only between **Sign in** and the prompt, in a property that is neither observed nor
/// printed, and drops it as soon as the job is over, cancelled or the guide closes.
///
/// All guide state lives here, not in the views, so a redraw loses nothing. A closed window releases
/// the controller and with it this model: the guide then starts again at page one, with its drafts
/// and sign-in form gone, while what was applied at once (language, appearance, lock screen) and a
/// sign-in job that is running stay.
@MainActor
@Observable
final class FirstRunModel {
  unowned let controller: PanelController

  /// What the guide waits on. A key is in the set while its action runs; a second request for the
  /// same key does nothing.
  enum Pending: Hashable, Sendable {
    case language, theme, performance, preferences, lockScreen
    case signIn, setup, cancel, setupCancel, signOut, subscriptions
  }

  /// What **Import my subscriptions** last did.
  enum SubscriptionImport: Equatable, Sendable {
    /// This many wallpapers went to Downloads.
    case queued(Int)
    /// The library already has every subscribed wallpaper.
    case upToDate
  }

  /// What the guide found when it opened, which Skip puts back.
  struct Initial: Equatable, Sendable {
    var mode: AppThemePreferences.Mode
    /// `AppLanguageStore.systemChoice` or a shipped tag.
    var language: String
    var lockScreen: Bool
  }

  /// What **Sign in** made of the form.
  enum Submission: Equatable, Sendable {
    /// Started; the sign-in now runs.
    case started
    /// The account field is not a Steam login name; focus it.
    case invalidAccount
    /// No password was typed; focus it.
    case missingPassword
    /// The request failed or was refused; the reason is on the page.
    case failed
  }

  // MARK: State

  /// Whether the guide is on screen, from the host's point of view.
  private(set) var isOpen = false
  private(set) var step = WelcomeStep.language
  /// The page's one message: the failure of the last action, cleared by every action and every move.
  private(set) var error: String?
  private(set) var pending = Set<Pending>()
  private(set) var initial: Initial?
  var performance = WelcomePerformanceDraft()
  var preferences = WelcomePreferenceDraft()
  /// The Steam account name typed so far. It survives page jumps; the password does not leave the
  /// field it is typed into until **Sign in**.
  var signInAccount = ""
  /// **Keep me signed in on this Mac**.
  var remembersSession = true
  /// The password field shows what is typed instead of dots. Guide state, like the rest: a redraw or
  /// a page jump keeps it; opening the guide and **Sign in** put the dots back.
  var revealsPassword = false
  /// A finished sign-in job stays in the downloads list; once the person signs out it no longer counts.
  /// It lives as long as the panel (this model goes with the controller), so a guide replayed from
  /// Settings does not show the forgotten account as signed in again; only a new **Sign in** or
  /// **Check ownership again** makes the job count once more.
  private(set) var dismissedJob = false
  /// **Import wallpapers** was chosen and the library's Import popover waits for the window to have
  /// drawn Installed (`openWaitingImportPopover()`).
  private(set) var importPopoverIsWaiting = false
  /// The outcome of **Import my subscriptions**, while the panel lives.
  private(set) var subscriptionImport: SubscriptionImport?
  /// Counted up when the page title or the footer's Continue should take VoiceOver focus.
  private(set) var titleFocusRequest = 0
  private(set) var continueFocusRequest = 0

  /// The password between **Sign in** and Steam's prompt. Never observed, never logged.
  @ObservationIgnored private var secret: String?
  @ObservationIgnored private var setupRequested = false
  @ObservationIgnored private var lastFocusKey: SteamFocusTarget.Key?
  /// Answers Steam's password prompt the moment the sign-in job asks, whichever page is on show.
  /// Runs only while the guide is open.
  @ObservationIgnored private var signInWatch: ObservationLoop?

  init(controller: PanelController) { self.controller = controller }

  /// The key a Steam answer goes out under, which also says whether one is on its way.
  static func inputKey(for jobID: String) -> String {
    PanelActionCoordinator.key("downloadInput", id: jobID)
  }

  // MARK: Opening and closing

  /// Opens at the first page with nothing drafted. The host calls it when the guide appears, the
  /// first time or because Settings asked for it again.
  func open() {
    guard !isOpen else { return }
    isOpen = true
    step = .language
    error = nil
    performance.clear()
    preferences.clear()
    secret = nil
    revealsPassword = false
    setupRequested = false
    lastFocusKey = nil
    let account = controller.steamAccount
    remembersSession = account.remembersSession
    if signInAccount.isEmpty { signInAccount = account.suggested }
    initial = Initial(
      mode: controller.themePreferences.mode,
      language: controller.languagePreference?.tag ?? AppLanguageStore.systemChoice,
      lockScreen: controller.lockScreenState.isRequested)
    let watch = ObservationLoop(
      track: { [unowned self] in _ = self.signInJob }, onChange: { [unowned self] in self.drive() })
    signInWatch = watch
    watch.start()
  }

  /// Closes the guide's own state; the host calls it when the guide goes away. Whatever Steam was
  /// asked keeps running; the held password goes.
  func close() {
    isOpen = false
    secret = nil
    signInWatch?.stop()
    signInWatch = nil
  }

  /// Ends the guide: the first-run flag is set unless it already is (a guide replayed from Settings
  /// leaves it alone), and the guide is no longer requested.
  func finish() {
    if !controller.welcomeSeen { controller.markWelcomeSeen() }
    controller.shell.isWelcomeRequested = false
    close()
  }

  /// **Browse the Workshop**: ends the guide, then opens Steam Workshop.
  @discardableResult
  func browse() -> Task<Void, Never> {
    finish()
    return controller.launch(PanelActionCoordinator.key("navigate"), policy: .latestWins) {
      [controller] in try await controller.navigate(.workshop)
    }
  }

  /// **Import wallpapers**: ends the guide, shows Installed and asks for the library's Import
  /// popover, which explains what an import does and what happens to a wallpaper the library
  /// already holds, rather than going straight to the file picker.
  @discardableResult
  func importWallpapers() -> Task<Void, Never> {
    finish()
    return controller.launch(PanelActionCoordinator.key("navigate"), policy: .latestWins) {
      [self, controller] in
      try await controller.navigate(.wallpaper)
      importPopoverIsWaiting = true
    }
  }

  /// Opens the Import popover **Import wallpapers** asked for. The host calls it once the window has
  /// drawn the page change: the root closes every popover when the page changes, and a popover
  /// opened before that (a guide replayed from Settings comes back to Installed) would stay on
  /// screen while the window believed none was open, which the support offer waits on.
  func openWaitingImportPopover() {
    guard importPopoverIsWaiting else { return }
    importPopoverIsWaiting = false
    controller.library.openImport(from: .page)
  }

  // MARK: Moving

  /// Whether the footer's controls and the progress dots wait: a choice is being committed, and the
  /// guide must not leave a partly submitted operation.
  var navigationBusy: Bool {
    !pending.isDisjoint(with: [.language, .theme, .performance, .preferences, .lockScreen])
  }

  func go(to destination: WelcomeStep) {
    guard !navigationBusy else { return }
    step = destination
    error = nil
    // The Preferences page carries the performance data switch, so it answers the one-time
    // question; someone who leaves the guide before reaching it is asked once later instead.
    if destination == .preferences { controller.store.supportPrompt?.recordTelemetryAsked() }
  }

  func next() { if let next = step.next { go(to: next) } }
  func back() { if let previous = step.previous { go(to: previous) } }

  /// The shape of every action: refuses a repeat, shows a failure on the page and reports whether it
  /// worked. The failure never reaches the window banner, which sits behind the guide.
  @discardableResult
  private func perform(_ key: Pending, _ work: () async throws -> Void) async -> Bool {
    guard !pending.contains(key) else { return false }
    pending.insert(key)
    error = nil
    defer { pending.remove(key) }
    do {
      try await work()
      return true
    } catch is CancellationError {
      return false
    } catch {
      self.error = error.localizedDescription
      return false
    }
  }

  // MARK: Page 1: language and appearance

  /// The language chosen, `AppLanguageStore.systemChoice` while the app follows macOS.
  var languageChoice: String {
    controller.languagePreference?.tag ?? AppLanguageStore.systemChoice
  }

  var appearance: AppThemePreferences.Mode { controller.themePreferences.mode }

  /// Applies a language at once: the guide, the panel and the import picker switch together.
  func chooseLanguage(_ tag: String) async {
    guard tag != languageChoice else { return }
    let language = AppLanguage.named(tag)
    guard language != nil || tag == AppLanguageStore.systemChoice else { return }
    await perform(.language) { try await controller.setLanguage(language) }
  }

  func chooseAppearance(_ mode: AppThemePreferences.Mode) async {
    guard mode != appearance else { return }
    await perform(.theme) { try controller.setThemeMode(mode) }
  }

  /// Puts back the appearance and then the language the guide opened with, then moves on. A failed
  /// restore is silent: moving clears the message.
  func skipLanguage() async {
    if let initial {
      if appearance != initial.mode { await chooseAppearance(initial.mode) }
      if languageChoice != initial.language { await chooseLanguage(initial.language) }
    }
    next()
  }

  // MARK: Page 2: Steam

  var signInJob: DownloadRow? { controller.steamSignInRow }
  var signInRequest: DownloadRequestRow? {
    controller.downloadRequestRow(for: WorkshopStore.signInRequestID)
  }

  /// Which of the Steam page's states is showing.
  var phase: SteamSignInPhase {
    SteamSignInPhase.resolve(
      job: signInJob, request: signInRequest, savedAccount: controller.steamAccount.saved,
      dismissedJob: dismissedJob)
  }

  /// SteamCMD's state, for the form's label and the setup card.
  var setup: SteamSetupState { controller.steamSetup }

  /// Whether the password is held for Steam's prompt.
  var holdsSecret: Bool { secret != nil }

  /// What the Steam page's status card says, which VoiceOver hears whenever it changes; nil while
  /// the form shows.
  var steamStatus: String? { phase.statusTitle(setupStatus: setup.status) }

  /// How a change of the Steam status reaches VoiceOver: politely, after what is being read. A
  /// seam: tests record it.
  @ObservationIgnored var announce: @MainActor (String) -> Void = { WelcomeAnnouncer.polite($0) }

  /// Whether Steam waits for the person and the guide is on another page.
  var steamNeedsAttention: Bool {
    guard step != .steam, let job = signInJob else { return false }
    return SteamSignInPhase.needsAttention(
      job: job, answerInFlight: controller.isBusy(Self.inputKey(for: job.id)),
      holdsSecret: holdsSecret)
  }

  /// Whether Steam's answer is on its way, so the response field waits.
  func isAnswering(_ job: DownloadRow) -> Bool { controller.isBusy(Self.inputKey(for: job.id)) }

  /// What **Sign in** checks before anything reaches Steam: a login name (letters, digits and
  /// underscores, not `anonymous`) and a password. The password is not trimmed.
  static func problem(account: String, password: String) -> Submission? {
    let trimmed = account.trimmingCharacters(in: .whitespacesAndNewlines)
    if WorkshopDownloader.normalizedAccount(trimmed) == nil { return .invalidAccount }
    if password.isEmpty { return .missingPassword }
    return nil
  }

  /// Checks the form before anything is sent: puts the problem on the page and says which field
  /// to focus, or returns nil when the form is fine. The account is trimmed in place.
  func validateSignIn(password: String) -> Submission? {
    signInAccount = signInAccount.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let problem = Self.problem(account: signInAccount, password: password) else {
      return nil
    }
    error =
      problem == .invalidAccount
      ? L("Enter your Steam account name: the login name, not the profile name. Letters, numbers and underscores only.")
      : L("Enter your Steam password.")
    return problem
  }

  /// **Sign in**. Checks the form (nothing is sent when it is wrong), holds the password for Steam's
  /// prompt and starts the sign-in; when SteamCMD is missing the request waits at its setup stage and
  /// the install starts too, because installing it is part of signing in.
  @discardableResult
  func submitSignIn(password: String) async -> Submission {
    if let problem = validateSignIn(password: password) { return problem }
    let account = signInAccount
    secret = password
    revealsPassword = false
    dismissedJob = false
    setupRequested = false
    let started = await perform(.signIn) {
      try await controller.steamSignIn(account: account, remembersSession: remembersSession)
    }
    guard started else {
      secret = nil
      return .failed
    }
    drive()
    await installSteamCMDIfWaiting()
    return .started
  }

  /// With SteamCMD missing the request waits at the setup stage. Installing it is part of signing
  /// in, asked once: not while a setup runs, is finished, or keeps a copy that needs approval.
  private func installSteamCMDIfWaiting() async {
    let setup = self.setup
    guard signInRequest?.stage == .setup, !setup.isBusy, !setup.isReady,
      setup.candidatePath == nil, !setupRequested
    else { return }
    setupRequested = true
    await perform(.setup) { try await controller.installSteamCMD() }
  }

  /// Answers Steam's password prompt with the held password exactly once; anything else Steam asks
  /// (a Steam Guard code, an approval on the phone) is the person's. Called whenever the job moves.
  func drive() {
    guard let job = signInJob else { return }
    // The password is held across the request that starts the job; before it exists there is
    // nothing to answer and nothing to drop.
    guard job.isPending else {
      if !pending.contains(.signIn) { secret = nil }
      return
    }
    guard job.promptIsSecret, let value = secret, !isAnswering(job) else { return }
    secret = nil
    controller.launch(Self.inputKey(for: job.id)) { [controller] in
      try await controller.submitDownloadInput(value, toJob: job.id)
    }
  }

  /// A typed answer to Steam's prompt (a Steam Guard code, or the password when the guide holds
  /// none). Empty answers are ignored; the field is cleared by its caller before this runs.
  func submitResponse(_ value: String, toJob job: DownloadRow) {
    guard !value.isEmpty else { return }
    controller.launch(Self.inputKey(for: job.id)) { [controller] in
      try await controller.submitDownloadInput(value, toJob: job.id)
    }
  }

  /// Cancels what the guide started: the retained request, a setup the guide began, a running job.
  func cancelSignIn() async {
    secret = nil
    let job = signInJob
    if signInRequest != nil {
      await perform(.cancel) {
        try await controller.removeDownloadRequest(id: WorkshopStore.signInRequestID)
      }
      // A SteamCMD install the person started elsewhere is not cancelled.
      if setup.isBusy && setupRequested {
        await perform(.setupCancel) { try await controller.cancelSteamCMDSetup() }
      }
    }
    if let job, job.isPending {
      await perform(.cancel) { try await controller.cancelDownload(id: job.id) }
    }
  }

  /// **Skip for now** and **Skip and cancel sign-in**: leaves Steam for the first download to ask.
  func skipSteam() async {
    await cancelSignIn()
    next()
  }

  /// **Check ownership again**: a fresh sign-in of the signed-in account; Steam asks for the password
  /// again unless the session was kept.
  func checkOwnership() async {
    let account = phase.signedInAccount
    guard !account.isEmpty else { return }
    dismissedJob = false
    await perform(.signIn) {
      try await controller.steamSignIn(account: account, remembersSession: remembersSession)
    }
  }

  /// **Use a different account**: asks, then forgets the saved sign-in. When none is left the form
  /// comes back, even over a finished job.
  func useDifferentAccount() async {
    let signedOut = await perform(.signOut) { try await controller.logOutSteam() }
    if signedOut, controller.steamAccount.saved == nil { dismissedJob = true }
  }

  /// The import card is on screen: the guide has offered it, so the one-time offer is not needed.
  func subscriptionsOffered() { controller.store.supportPrompt?.recordSubscriptionsOffered() }

  /// Whether Steam Community is signed in, so the import needs no sign-in window first.
  var isSignedInToSteamCommunity: Bool { controller.workshop.steamWebSession != nil }

  /// **Import my subscriptions**: Steam's own sign-in window when Steam Community is not signed in
  /// yet, then every subscribed wallpaper the library lacks goes to Downloads, behind the guide.
  /// A window closed without signing in changes nothing.
  func importSubscriptions() async {
    await perform(.subscriptions) {
      guard let queued = try await controller.importSteamSubscriptions() else { return }
      subscriptionImport = queued > 0 ? .queued(queued) : .upToDate
    }
  }

  func installSteamCMD() async { await perform(.setup) { try await controller.installSteamCMD() } }
  func locateSteamCMD() async { await perform(.setup) { try await controller.locateSteamCMD() } }
  func approveSteamCMD() async { await perform(.setup) { try await controller.approveSteamCMD() } }

  // MARK: Steam focus

  /// Where focus should go now that the Steam page changed, or nil when nothing moved or nothing
  /// needs it. The caller applies it only if focus has nowhere to be.
  func steamFocusTarget() -> SteamFocusTarget? {
    let phase = self.phase
    let key = SteamFocusTarget.Key(
      job: signInJob, request: signInRequest, signedInAccount: phase.signedInAccount,
      pageError: error)
    guard key != lastFocusKey else { return nil }
    lastFocusKey = key
    return SteamFocusTarget.resolve(
      job: signInJob, hasRequest: signInRequest != nil, isSignedIn: phase.isSignedIn,
      showsForm: phase.showsForm, hasPageError: error != nil)
  }

  func requestTitleFocus() { titleFocusRequest &+= 1 }
  func requestContinueFocus() { continueFocusRequest &+= 1 }

  // MARK: Page 3: performance

  /// What is saved: the limit and the render scale the engine reports.
  var savedFrameRateCap: UInt32? { controller.store.settingsSnapshot.frameRateCap }
  var savedRenderScale: Float { controller.store.settingsSnapshot.preferredRenderScale }
  var frameRateSlider: FrameRateCapSlider {
    FrameRateCapSlider(displays: controller.store.settingsSnapshot.displays)
  }

  var shownFrameRateCap: UInt32? { performance.frameRateCap(saved: savedFrameRateCap) }
  var shownPreset: QualityPreset? {
    performance.activePreset(savedCap: savedFrameRateCap, savedScale: savedRenderScale)
  }

  /// Where the slider sits for the draft, or the saved limit.
  var frameRatePosition: Int { frameRateSlider.position(forCap: shownFrameRateCap) }

  func choosePreset(_ preset: QualityPreset) { performance.choose(preset) }

  func setFrameRatePosition(_ position: Int) {
    performance.setFrameRateCap(frameRateSlider.cap(atPosition: position))
  }

  var unsavedPerformanceCount: Int {
    performance.changes(savedCap: savedFrameRateCap, savedScale: savedRenderScale).count
  }

  /// **Continue** on Performance: sends each changed draft, in the order chosen, then moves on. A
  /// refusal stays on the page with its reason; what was already sent now matches the engine and the
  /// rest stay drafts.
  func continuePerformance() async {
    guard !navigationBusy else { return }
    let changes = performance.changes(savedCap: savedFrameRateCap, savedScale: savedRenderScale)
    guard !changes.isEmpty else {
      performance.clear()
      next()
      return
    }
    let committed = await perform(.performance) {
      for change in changes {
        switch change {
        case .frameRateCap(let cap): try await controller.setFrameRateCap(cap.map(Int.init))
        case .renderScale(let scale): try await controller.setRenderScale(Double(scale))
        }
      }
    }
    if committed {
      performance.clear()
      next()
    }
  }

  func skipPerformance() {
    guard !navigationBusy else { return }
    performance.clear()
    next()
  }

  // MARK: Page 4: preferences

  /// What the engine, macOS and the telemetry service report for the drafted preferences.
  var savedPreferences: WelcomePreferenceValues {
    WelcomePreferenceValues(
      launchAtLogin: controller.generalSettings.launchAtLogin.isOn,
      keepsWindowsOnWallpaperClick: controller.desktopSettings.keepsWindowsOnWallpaperClick,
      batteryMode: controller.store.settingsSnapshot.batteryMode,
      sendsPerformanceData: controller.performanceData?.isEnabled ?? false)
  }

  var shownPreferences: WelcomePreferenceValues { preferences.values(saved: savedPreferences) }

  var unsavedPreferencesCount: Int { preferences.changes(saved: savedPreferences).count }

  /// **Continue** on Preferences: the same ordered commit as Performance.
  func continuePreferences() async {
    guard !navigationBusy else { return }
    let changes = preferences.changes(saved: savedPreferences)
    guard !changes.isEmpty else {
      preferences.clear()
      next()
      return
    }
    let committed = await perform(.preferences) {
      for change in changes {
        switch change {
        case .launchAtLogin(let enabled): try await controller.setLaunchAtLogin(enabled)
        case .keepsWindows(let keeps): try await controller.setKeepsWindowsOnWallpaperClick(keeps)
        case .batteryMode(let mode): try await controller.setBatteryMode(mode)
        case .performanceData(let enabled): try await controller.setSendsPerformanceData(enabled)
        }
      }
    }
    if committed {
      preferences.clear()
      next()
    }
  }

  /// **Skip** on Preferences: drops the drafts, puts the lock screen back if the guide changed it,
  /// and moves on.
  func skipPreferences() async {
    guard !navigationBusy else { return }
    preferences.clear()
    if let initial, controller.lockScreenState.isRequested != initial.lockScreen {
      await perform(.lockScreen) { try await controller.setLockScreenEnabled(initial.lockScreen) }
    }
    next()
  }

  /// The lock screen applies at once, like Settings. A refusal leaves the switch where the service
  /// says it is and shows why.
  func setLockScreen(_ enabled: Bool) async {
    await perform(.lockScreen) { try await controller.setLockScreenEnabled(enabled) }
  }

  /// The lock screen row as it reads now: why it is unavailable, that it is working, or what it
  /// promises.
  var lockScreenRow: LockScreenRow {
    LockScreenRow.make(
      state: controller.lockScreenState, requestIsRunning: pending.contains(.lockScreen),
      isCommitting: pending.contains(.preferences))
  }

  /// Whether the Launch at login switch can be used: outside Applications the app cannot register
  /// itself, but a login item the person switched off in System Settings can still be asked for, and
  /// the row then says where to allow it.
  var canChangeLaunchAtLogin: Bool {
    !pending.contains(.preferences) && controller.generalSettings.launchAtLogin.isAvailable
  }

  /// Whether the Send performance data switch can be used: a run without the telemetry service
  /// (tests, a diagnostic run) has nothing to turn on.
  var canChangePerformanceData: Bool {
    !pending.contains(.preferences) && controller.performanceData != nil
  }

  // MARK: Page 6: start

  var recap: WelcomeRecap {
    WelcomeRecap.make(
      languageName: AppLanguage.named(languageChoice)?.name, appearance: appearance,
      phase: phase, job: signInJob, request: signInRequest, setupStatus: setup.status,
      unsavedPerformance: unsavedPerformanceCount, unsavedPreferences: unsavedPreferencesCount)
  }
}

/// What the Animate lock screen row says and whether its switch can be used. Unlike the other rows it
/// is not a draft: it applies at once, so it waits for the service while it works.
struct LockScreenRow: Equatable {
  enum Note: Equatable {
    /// Why it cannot be turned on: the macOS version, or no service.
    case unavailable(String)
    /// The service is working, in its own words with an ellipsis.
    case working(String)
    /// The default: "Experimental. Applies right away."
    case promise
  }

  let note: Note
  let isSwitchEnabled: Bool

  /// - Parameters:
  ///   - requestIsRunning: the guide's own change is on its way to the service.
  ///   - isCommitting: **Continue** is committing the drafts, which holds every control.
  @MainActor
  static func make(state: LockScreenState, requestIsRunning: Bool, isCommitting: Bool) -> LockScreenRow
  {
    guard state.isAvailable else {
      return LockScreenRow(note: .unavailable(state.statusText), isSwitchEnabled: false)
    }
    let working = requestIsRunning || state.isBusy
    if working {
      // The service's words while it works; "Updating…" for the moment before it says anything.
      let text = state.isBusy ? state.statusText : L("Updating") + "…"
      return LockScreenRow(note: .working(text), isSwitchEnabled: false)
    }
    return LockScreenRow(note: .promise, isSwitchEnabled: !isCommitting)
  }
}

/// The recap of the Start page: what the guide set, and what it holds back.
struct WelcomeRecap: Equatable {
  struct Unsaved: Equatable, Identifiable {
    let step: WelcomeStep
    let count: Int
    var id: WelcomeStep { step }
  }

  /// The language's own name, nil while the app follows macOS (the page then says System (Auto)).
  let languageName: String?
  let appearance: AppThemePreferences.Mode
  /// What the Steam row says.
  let steam: String
  /// Steam is mid-sign-in, so the row offers **Finish sign-in**.
  let offersFinishingSignIn: Bool
  /// The pages with drafts that were not saved, Performance then Preferences.
  let unsaved: [Unsaved]

  @MainActor
  static func make(
    languageName: String?, appearance: AppThemePreferences.Mode, phase: SteamSignInPhase,
    job: DownloadRow?, request: DownloadRequestRow?, setupStatus: String,
    unsavedPerformance: Int, unsavedPreferences: Int
  ) -> WelcomeRecap {
    let account = phase.signedInAccount
    let steam: String
    if !account.isEmpty {
      steam = L("Signed in as \(account)")
    } else if let job, job.isPending {
      steam = job.status.isEmpty ? L("Waiting for Steam") : job.status
    } else if let request {
      steam = request.stage == .setup ? setupStatus : request.stage.hint
    } else {
      steam = L("Not signed in. You’ll be asked at your first download.")
    }
    return WelcomeRecap(
      languageName: languageName, appearance: appearance, steam: steam,
      offersFinishingSignIn: account.isEmpty && (job?.isPending == true || request != nil),
      unsaved: [
        Unsaved(step: .performance, count: unsavedPerformance),
        Unsaved(step: .preferences, count: unsavedPreferences),
      ].filter { $0.count > 0 })
  }
}
