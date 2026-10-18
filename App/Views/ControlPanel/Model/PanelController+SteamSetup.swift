import AppKit
import Foundation

/// SteamCMD, Valve's download tool, and the shared scene resources that scene wallpapers need:
/// installing or locating the tool, allowing a copy macOS has not approved, and pointing the app at
/// an existing Wallpaper Engine installation instead of downloading its assets.
///
/// Every confirmation and picker is asked inside the command, in the original order, so an open
/// sheet holds the queue. Without a panel window each answers "no" and nothing happens.
extension PanelController {
  /// Installs SteamCMD, or tries again with the copy that is kept. Over an existing managed copy it
  /// asks first: the new copy replaces the current one only once it passes validation, and
  /// wallpapers and the saved sign-in are kept.
  func installSteamCMD() async throws {
    try await run(.queued) {
      let exists = FileManager.default.fileExists(atPath: ClientPaths.managedSteamCMDURL.path)
      if workshop.steamCMDSetup.retainedCandidateURL != nil {
        workshop.steamCMDSetup.retryInstallation()
        return
      }
      let approved =
        exists
        ? await dialogs.confirm(
          L("Reinstall SteamCMD?"),
          detail: L(
            "The new copy replaces the current one only after it passes validation. Wallpapers and your saved sign-in are kept."
          ),
          button: L("Reinstall")) : true
      if approved { workshop.steamCMDSetup.install(replacingExisting: exists) }
    }
  }

  /// Points the app at a SteamCMD the user already has: a file or a folder.
  func locateSteamCMD() async throws {
    try await run(.queued) {
      let panel = NSOpenPanel()
      panel.title = L("Locate SteamCMD")
      panel.canChooseDirectories = true
      panel.canChooseFiles = true
      if let url = await dialogs.choose(panel) { workshop.steamCMDSetup.selectExisting(at: url) }
    }
  }

  /// Allows the SteamCMD copy the app downloaded and keeps because macOS has not approved it, after
  /// showing its path and SHA-256 fingerprint. Approval covers exactly that copy: the quarantine
  /// flag is removed from it alone, and Gatekeeper and signature checks stay on for everything else.
  func approveSteamCMD() async throws {
    try await run(.queued) {
      let candidate = try await workshop.steamCMDSetup.prepareApproval()
      guard
        await dialogs.confirm(
          L("Allow this SteamCMD installation?"),
          detail: L(
            "macOS has not approved this software, and running it may put your data at risk. Only files matching this fingerprint are allowed, and the quarantine flag is removed from this copy only. Gatekeeper and signature checks stay on for everything else.\n\nPath: \(candidate.rootURL.path)\nSHA-256: \(candidate.fingerprint)"
          ),
          button: L("Allow This Copy and Continue"))
      else { return }
      workshop.steamCMDSetup.approveRetainedCandidate(candidate)
    }
  }

  /// Shows the kept SteamCMD copy in Finder.
  func revealSteamCMDCandidate() async throws {
    try await run(.queued) {
      if let url = workshop.steamCMDSetup.retainedCandidateURL {
        revealInFinder([url])
      }
    }
  }

  /// Deletes the kept SteamCMD copy after asking. The installed SteamCMD and the saved sign-in stay.
  func discardSteamCMDCandidate() async throws {
    try await run(.queued) {
      guard
        await dialogs.confirm(
          L("Discard downloaded SteamCMD?"),
          detail: L(
            "Only this downloaded copy is removed. The installed SteamCMD and your saved sign-in are kept."
          ),
          button: L("Discard Download"))
      else { return }
      workshop.steamCMDSetup.discardRetainedCandidate()
    }
  }

  /// Cancels the setup in progress. It never waits behind a renderer command, so cancelling stays
  /// possible while a native operation is in flight.
  func cancelSteamCMDSetup() async throws {
    try await run(.immediate) { workshop.steamCMDSetup.cancel() }
  }

  /// Uses an existing Wallpaper Engine installation's folder for the shared scene resources. A
  /// folder without the shared shaders and materials is refused with the reason. Located assets
  /// satisfy the need, so a waiting request for them is finished, not downloaded.
  func locateSceneAssets() async throws {
    try await run(.queued) {
      let panel = NSOpenPanel()
      panel.title = L("Locate Scene Assets")
      panel.canChooseDirectories = true
      panel.canChooseFiles = false
      guard let url = await dialogs.choose(panel) else { return }
      try configureSceneAssets(url)
      workshop.refreshSceneAssetsReadiness()
      workshop.removeDownloadRequest(id: WorkshopStore.sceneAssetsRequestID)
    }
  }
}
