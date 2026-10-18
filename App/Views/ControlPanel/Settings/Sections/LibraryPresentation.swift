import Foundation

/// What the SteamCMD group offers for the setup's state and the downloads that are running. The
/// view never decides which button exists or which is disabled; this does.
///
/// Installing, reinstalling and locating change what every download depends on, so they wait for the
/// downloads to finish and for any wallpaper command; Cancel is the one thing that stays possible
/// while setup works, until it is saving the installation.
struct LibrarySteamCMDPresentation: Equatable {
  enum Primary: Equatable {
    case install
    case reinstall
    /// A downloaded copy is kept, and installing carries on with it.
    case continueInstallation
  }

  /// Cancel installation replaces the other buttons while setup works.
  var showsCancel: Bool
  var cancelIsDisabled: Bool
  /// Nil while setup works.
  var primary: Primary?
  /// Install SteamCMD is the filled button until SteamCMD is ready; Reinstall is quiet.
  var primaryIsProminent: Bool
  var primaryIsDisabled: Bool
  var showsLocate: Bool
  var locateIsDisabled: Bool
  var showsApprove: Bool
  var approveIsDisabled: Bool
  /// A downloaded copy is kept: its path, Show in Finder and Discard…
  var showsCandidate: Bool
  var revealIsDisabled: Bool
  var discardIsDisabled: Bool
  /// "Installation changes are unavailable while downloads are running."
  var showsDownloadsNote: Bool

  static func make(
    setup: SteamSetupState, hasPendingDownload: Bool, isStoreBusy: Bool
  ) -> LibrarySteamCMDPresentation {
    make(
      isBusy: setup.isBusy, isReady: setup.isReady, canCancel: setup.canCancel,
      canApprove: setup.canApprove, hasCandidate: setup.candidatePath != nil,
      hasPendingDownload: hasPendingDownload, isStoreBusy: isStoreBusy)
  }

  /// The same from the facts of the setup, which is what the rules are written over.
  static func make(
    isBusy: Bool, isReady: Bool, canCancel: Bool, canApprove: Bool, hasCandidate: Bool,
    hasPendingDownload: Bool, isStoreBusy: Bool
  ) -> LibrarySteamCMDPresentation {
    let locked = isStoreBusy || isBusy || hasPendingDownload
    let primary: Primary = hasCandidate ? .continueInstallation : isReady ? .reinstall : .install
    return LibrarySteamCMDPresentation(
      showsCancel: isBusy, cancelIsDisabled: isStoreBusy || !canCancel,
      primary: isBusy ? nil : primary, primaryIsProminent: !isReady, primaryIsDisabled: locked,
      showsLocate: !isBusy, locateIsDisabled: locked, showsApprove: canApprove,
      approveIsDisabled: locked, showsCandidate: hasCandidate, revealIsDisabled: isStoreBusy,
      discardIsDisabled: locked, showsDownloadsNote: hasPendingDownload && !isBusy)
  }
}

/// What the Shared scene resources group says and offers: one line for where the resources stand, a
/// bar while they download, and the buttons that fit.
struct LibrarySceneResourcesPresentation: Equatable {
  enum Action: Equatable {
    /// Steam asks for a password or a Steam Guard code; the download dialog takes it.
    case finishSignIn
    case cancelQueuedDownload
    case cancelDownload
    /// A request waits for something; the dialog shows what.
    case continueSetup
    case removeRequest
    case download(installed: Bool)
    case locate
  }

  /// Where the resources stand, in the panel's language.
  var status: String
  /// The download is waiting or running.
  var isPending: Bool
  /// How far it has come; nil draws a bar that has no figure yet.
  var progress: Double?
  var error: String?
  var warnings: [String]
  /// The buttons, in the order they are drawn.
  var actions: [Action]
  /// Whether the filled style belongs to the action.
  func isProminent(_ action: Action) -> Bool {
    switch action {
    case .finishSignIn, .continueSetup: true
    case .download(let installed): !installed
    default: false
    }
  }
  var locateIsDisabled: Bool

  /// - Parameters:
  ///   - scene: the job that downloads the shared resources, while there is one.
  ///   - request: the retained request for them, while one waits for SteamCMD, the sign-in or the
  ///     user's go-ahead.
  ///   - isInstalled: the resources are in place and scene wallpapers can play.
  ///   - assetsWarning: why they are still missing after a download failed.
  @MainActor
  static func make(
    scene: DownloadRow?, request: DownloadRequestRow?, isInstalled: Bool, assetsWarning: String?,
    setupIsBusy: Bool, isStoreBusy: Bool
  ) -> LibrarySceneResourcesPresentation {
    let pending = scene?.isPending ?? false
    let signInNeeded =
      pending && scene?.isQueued == false
      && (scene?.prompt != nil || scene?.challenge != nil || scene?.isAuthenticating == true)
    let status: String
    if let scene {
      status = scene.status
    } else if let request {
      switch request.stage {
      case .setup: status = L("Waiting for SteamCMD setup.")
      case .account: status = L("Waiting for your Steam sign-in.")
      case .resources, .ready: status = L("Waiting for your go-ahead on the download.")
      }
    } else {
      status =
        isInstalled
        ? L("Installed. Scene wallpapers can play.")
        : L("Not installed. Scene wallpapers cannot play yet.")
    }
    var actions: [Action] = []
    if signInNeeded { actions.append(.finishSignIn) }
    if pending { actions.append(scene?.isQueued == true ? .cancelQueuedDownload : .cancelDownload) }
    if !pending, request != nil { actions += [.continueSetup, .removeRequest] }
    if !pending, request == nil { actions.append(.download(installed: isInstalled)) }
    if !pending { actions.append(.locate) }
    return LibrarySceneResourcesPresentation(
      status: status, isPending: pending, progress: pending ? scene?.clampedProgress : nil,
      error: scene?.errorMessage.flatMap { $0.isEmpty ? nil : $0 },
      warnings: [scene?.warning, assetsWarning].compactMap { $0 }.filter { !$0.isEmpty },
      actions: actions, locateIsDisabled: isStoreBusy || setupIsBusy)
  }
}

/// The Last check line of the Workshop updates group.
enum LibraryUpdatesNote {
  /// "Not checked yet.", or when the check ran, when and what it found.
  @MainActor
  static func text(_ updates: WorkshopUpdatesState, now: Date = Date(), locale: Locale) -> String {
    text(lastChecked: updates.lastChecked, count: updates.count, now: now, locale: locale)
  }

  @MainActor
  static func text(lastChecked: Date?, count: Int, now: Date = Date(), locale: Locale) -> String {
    guard let lastChecked else { return L("Not checked yet.") }
    let time = PlaylistState.changeTime(lastChecked, now: now, locale: locale)
    switch count {
    case 0: return L("\(time): everything is up to date.")
    case 1: return L("\(time): 1 wallpaper has an update. Update it from Installed.")
    default: return L("\(time): \(count) wallpapers have updates. Update them from Installed.")
    }
  }
}

/// How the Steam account row reads.
enum LibraryAccountNote {
  /// "Signed in as X", with why Log out waits while downloads run; "You sign in when a download
  /// starts." without an account.
  @MainActor
  static func text(account: String?, hasPendingDownload: Bool) -> String {
    guard let account else { return L("You sign in when a download starts.") }
    return hasPendingDownload
      ? L("Signed in as \(account) · log out once downloads finish") : L("Signed in as \(account)")
  }
}

/// The counts the Downloads at once menu offers: the queue's whole range, and the count in use when
/// it is above the range (a setting from a version that allowed more), so the menu can show it.
enum LibraryDownloadsMenu {
  static func choices(_ settings: LibrarySteamSettings) -> [Int] {
    let range = settings.concurrentDownloadsRange
    return Array(range.lowerBound...max(settings.concurrentDownloads, range.upperBound))
  }
}
