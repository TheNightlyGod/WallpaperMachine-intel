import Foundation

/// A retained download intent: the wallpaper (or the shared assets, or a sign-in) the user asked
/// for, kept while SteamCMD, the Steam account and the consent for shared resources are resolved.
struct DownloadRequestRow: Identifiable, Equatable {
  let id: String
  let wallpaperID: String?
  let title: String
  let image: PanelImageSource?
  let account: String
  let rememberSession: Bool
  /// The first prerequisite still needed.
  let stage: WorkshopDownloadStage
  /// Restored after a relaunch, waiting for an explicit continue.
  let isPaused: Bool
  let appliesOnArrival: Bool

  init(
    id: String, wallpaperID: String? = nil, title: String, image: PanelImageSource? = nil,
    account: String = "", rememberSession: Bool = true, stage: WorkshopDownloadStage,
    isPaused: Bool = false, appliesOnArrival: Bool = false
  ) {
    self.id = id
    self.wallpaperID = wallpaperID
    self.title = title
    self.image = image
    self.account = account
    self.rememberSession = rememberSession
    self.stage = stage
    self.isPaused = isPaused
    self.appliesOnArrival = appliesOnArrival
  }

  @MainActor
  init(_ request: WorkshopDownloadRequest, stage: WorkshopDownloadStage, appliesOnArrival: Bool) {
    self.init(
      id: request.id, wallpaperID: request.item?.id,
      title: request.item?.title ?? WorkshopDownloadStage.itemlessTitle(id: request.id),
      image: request.item?.thumbnail, account: request.account,
      rememberSession: request.rememberSession, stage: stage, isPaused: request.isPaused,
      appliesOnArrival: appliesOnArrival)
  }
}

extension WorkshopDownloadStage {
  /// The title of a job or request that carries no Workshop item: the shared assets or a sign-in.
  @MainActor
  static func itemlessTitle(id: String) -> String {
    id == WorkshopStore.signInRequestID ? L("Steam sign-in") : L("Scene assets")
  }

  /// What a retained request is waiting for, in one line.
  @MainActor
  var hint: String {
    switch self {
    case .setup: L("Waiting for SteamCMD setup.")
    case .account: L("Waiting for your Steam sign-in.")
    case .resources: L("Waiting for your go-ahead on shared resources.")
    case .ready: L("Starting…")
    }
  }

  /// The download dialog's title at this stage.
  @MainActor
  var dialogTitle: String {
    switch self {
    case .setup: L("Install SteamCMD")
    case .account: L("Sign in to Steam")
    case .resources: L("Shared resources needed")
    case .ready: L("Starting download")
    }
  }
}
