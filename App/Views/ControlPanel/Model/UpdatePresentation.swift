import Foundation

/// What Settings › About › Updates shows and offers for an `AppUpdateState`: one status line, at
/// most one primary action, and the two secondary buttons.
///
/// The view never decides which button to show; this does. The matrix is the contract:
///
/// | state | status line | action | releases | reveal |
/// |---|---|---|---|---|
/// | unsupported | in-app updates only in installed builds | none | yes | no |
/// | idle, checking | not yet checked, checking | Check for Updates | no | no |
/// | noRelease, upToDate | no published update, up to date | Check Again | no | no |
/// | available | version is available | Download Update | no | no |
/// | manual | version is available | none | yes | no |
/// | downloading | downloading, percent | Downloading N percent | no | no |
/// | ready | version is ready | Restart and Install | no | yes |
/// | preparing | preparing | Cancel | no | no |
/// | error while installing a known version | the error | Retry installation | yes | no |
/// | any other error | the error | Retry | yes | no |
struct UpdatePresentation: Equatable {
  enum Status: String, Sendable {
    case unsupported, idle, checking, noRelease, upToDate, available, manual
    case downloading, ready, preparing, error
  }

  /// The one thing the primary button does. Each maps to a `PanelController` method of the same name.
  enum Action: String, Sendable {
    case checkForUpdates, downloadUpdate, installUpdate, cancelUpdate
  }

  struct Download: Equatable, Sendable {
    /// 0...100.
    var percent: Double
    var transferred: Int64
    var total: Int64
  }

  var status: Status
  var statusText: String
  /// The primary button's action, nil when the state offers none.
  var action: Action?
  /// The primary button's label, empty when there is no action.
  var actionLabel: String
  /// Whether the primary button is drawn filled: an update is waiting to be taken.
  var isActionProminent: Bool
  /// "Open GitHub Releases", the manual way to the update.
  var showsReleases: Bool
  /// "Show in Finder" for a downloaded update.
  var showsReveal: Bool
  /// Checking, downloading or preparing: the card is working.
  var isBusy: Bool
  /// Only while downloading.
  var download: Download?
  /// The version the latest published release's notes are for, nil without notes.
  var notesVersion: String?
  /// The release notes, shown whether or not that release is newer than this build. Empty when none.
  var notes: [ReleaseNotes.Section]

  var showsAction: Bool { action != nil }

  /// Whether the "What's new" disclosure has anything to show: some section carries an item.
  var hasNotes: Bool { notes.contains { !$0.items.isEmpty } }

  /// The fixed texts around the card.
  @MainActor static var footnote: String {
    L(
      "Updates are checked against the latest published GitHub Release. Download and restart-install happen only after you confirm."
    )
  }
  @MainActor static var releasesLabel: String { L("Open GitHub Releases") }
  @MainActor static var revealLabel: String { L("Show in Finder") }
  @MainActor static var progressLabel: String { L("Update download progress") }

  /// `locale` words the time a rate limit ends in.
  @MainActor
  init(
    state: AppUpdateState, notes: ReleaseNotes? = nil, rateLimitedUntil: Date? = nil,
    locale: Locale = .current
  ) {
    self.notes = notes?.sections ?? []
    notesVersion = notes?.version
    isBusy = state.isBusy
    download = nil
    switch state {
    case .unsupported:
      status = .unsupported
      statusText = L("In-app updates are available only in installed builds.")
    case .idle:
      status = .idle
      statusText = L("Updates not yet checked")
    case .checking:
      status = .checking
      statusText = L("Checking for updates...")
    case .noRelease:
      status = .noRelease
      statusText = L("No published update is available yet. You can keep using this version.")
    case .upToDate:
      status = .upToDate
      statusText = L("Up to date")
    case .available(_, let version):
      status = .available
      statusText = L("Version \(version) is available from GitHub Releases.")
    case .manual(_, let version):
      status = .manual
      statusText = L("Version \(version) is available from GitHub Releases.")
    case .downloading(_, let version, let value, let done, let expected, _):
      status = .downloading
      statusText = L("Downloading version \(version) — \(Int(value.rounded())) percent")
      download = Download(percent: value, transferred: done, total: expected)
    case .ready(_, let version):
      status = .ready
      statusText = L("Version \(version) is ready. Restart the app to install it.")
    case .preparing:
      status = .preparing
      statusText = L("Preparing update…")
    case .error(_, _, let code, _):
      status = .error
      statusText = Self.errorText(code, rateLimitedUntil: rateLimitedUntil, locale: locale)
    }

    switch state {
    case .unsupported, .manual:
      (action, actionLabel) = (nil, "")
    case .available:
      (action, actionLabel) = (.downloadUpdate, L("Download Update"))
    case .ready:
      (action, actionLabel) = (.installUpdate, L("Restart and Install"))
    case .preparing:
      (action, actionLabel) = (.cancelUpdate, L("Cancel"))
    case .error(_, .install, _, let version) where version != nil:
      (action, actionLabel) = (.installUpdate, L("Retry installation"))
    case .error:
      (action, actionLabel) = (.checkForUpdates, L("Retry"))
    case .upToDate, .noRelease:
      (action, actionLabel) = (.checkForUpdates, L("Check Again"))
    case .downloading(_, _, let value, _, _, _):
      (action, actionLabel) = (.downloadUpdate, L("Downloading \(Int(value.rounded())) percent"))
    case .checking, .idle:
      (action, actionLabel) = (.checkForUpdates, L("Check for Updates"))
    }
    isActionProminent = status == .available || status == .ready

    switch state {
    case .unsupported, .manual, .error: showsReleases = true
    default: showsReleases = false
    }
    if case .ready = state { showsReveal = true } else { showsReveal = false }
  }

  /// The sentence for a failed update. A rate limit names the time GitHub accepts anonymous requests
  /// again when it is known.
  @MainActor
  static func errorText(
    _ code: AppUpdateErrorCode, rateLimitedUntil: Date? = nil, locale: Locale = .current
  ) -> String {
    switch code {
    case .network:
      return L("Couldn't reach GitHub Releases. Check your connection and try again.")
    case .rateLimited:
      guard let rateLimitedUntil else {
        return L(
          "GitHub's hourly limit for anonymous update checks is used up on this network (60 requests an hour, shared by every app and device on the same public IP). Try again later."
        )
      }
      let time = rateLimitedUntil.formatted(
        Date.FormatStyle(date: .omitted, time: .shortened).locale(locale))
      return L(
        "GitHub's hourly limit for anonymous update checks is used up on this network (60 requests an hour, shared by every app and device on the same public IP). Try again after \(time)."
      )
    case .configuration:
      return L("The GitHub Release update metadata is unavailable.")
    case .verification:
      return L("The update couldn't be verified, so it wasn't installed.")
    case .permission:
      return L("The updater doesn't have permission to install this update.")
    case .unknown:
      return L("The update couldn't be completed. Try again or install it from GitHub Releases.")
    }
  }
}
