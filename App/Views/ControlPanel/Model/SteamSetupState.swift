import Foundation

/// Where SteamCMD stands, for the download dialog's setup stage, the title bar's setup pill and the
/// gate on retrying a failed download: nothing downloads without it.
struct SteamSetupState: Equatable {
  /// A short sentence for the state: "Not installed", "Downloading SteamCMD…", "Ready"...
  let status: String
  /// Checking, downloading, extracting, validating or saving: the title bar says SteamCMD is being
  /// set up, and the install and locate buttons wait.
  let isBusy: Bool
  /// A usable SteamCMD is selected.
  let isReady: Bool
  /// What went wrong, when setup failed.
  let errorDetail: String?
  /// The failure is a retained copy that macOS has not approved and the user may allow.
  let canApprove: Bool
  /// The folder of the retained candidate, if one is kept.
  let candidatePath: String?
  /// Setup can be cancelled: it is busy and not yet saving.
  let canCancel: Bool
  /// How much of the download has arrived; nil unless a total is known, so an unknown size is an
  /// indeterminate bar and never 0%.
  let progress: Double?

  @MainActor
  init(_ setup: SteamCMDSetupStore) {
    var detail: String?
    var approvable = false
    var progress: Double?
    switch setup.state {
    case .idle: status = L("Not installed")
    case .checking: status = L("Checking SteamCMD…")
    case .downloading(let received, let expected):
      status = L("Downloading SteamCMD…")
      if let expected, expected > 0 { progress = min(1, Double(received) / Double(expected)) }
    case .extracting: status = L("Extracting SteamCMD…")
    case .validating: status = L("Validating SteamCMD…")
    case .committing: status = L("Saving installation…")
    case .ready: status = L("Ready")
    case .cancelled: status = L("Installation cancelled")
    case .failed(let issue):
      status = L("Setup needs attention")
      detail = issue.detail
      approvable = issue.kind == .securityApprovalRequired && setup.retainedCandidateURL != nil
    }
    isBusy = setup.isBusy
    isReady = setup.selectedRuntime != nil
    errorDetail = detail
    canApprove = approvable
    candidatePath = setup.retainedCandidateURL?.path
    canCancel = setup.isBusy && setup.state != .committing
    self.progress = progress
  }
}
