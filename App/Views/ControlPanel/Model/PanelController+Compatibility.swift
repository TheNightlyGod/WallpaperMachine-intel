import Foundation

/// The Compatibility check card of the selected installed wallpaper on the target display: what the
/// app could establish about it before it plays, and which backend draws it now, if any.
struct CompatibilityState: Equatable {
  let wallpaperID: String
  let displayID: String
  /// The wallpaper's kind, which decides whether a reinstall can repair what is unavailable.
  let kind: WallpaperCompatibilityContext.Kind
  /// A check is being read.
  let isChecking: Bool
  /// The result for exactly this wallpaper and display, empty until a check ran.
  let checks: [WallpaperCompatibilityCheck]
  /// The backend that draws the wallpaper on this display now, from the live report of this wallpaper
  /// on this display's physical id. The absence of a report is never read as a backend.
  let backend: String?
  let fallbackReason: String?
  /// Why the wallpaper is held and not drawn when Native Metal could not draw it. Then `backend` is the
  /// engine's "unknown": nothing is drawing it.
  var failure: SceneFailureReport? = nil
  /// Checking is possible: the target is an enabled independent display with the wallpaper's
  /// options loaded and a frame rate to certify.
  let canCheck: Bool

  /// The counts the card summarizes in words, in the order it names them.
  var unavailableCount: Int { checks.filter { $0.status == .unavailable }.count }
  var warningCount: Int { checks.filter { $0.status == .warning }.count }
  var unknownCount: Int { checks.filter { $0.status == .unknown }.count }
  /// Some check ran and none found a problem.
  var foundNoProblems: Bool {
    !checks.isEmpty && unavailableCount == 0 && warningCount == 0 && unknownCount == 0
  }

  /// Only what a fresh copy from the Workshop repairs: an unavailable check of the installed files
  /// (the manifest or the entry file) of a wallpaper whose type is known. The lock screen, the
  /// target display, native video admission and the shared scene resources are unavailable for
  /// reasons a reinstall leaves as they are. The inspector also needs the wallpaper to be a
  /// Workshop item with no download under way before it offers Reinstall.
  var installedFilesAreUnavailable: Bool {
    kind != .unknown
      && checks.contains { $0.status == .unavailable && ["project", "entry"].contains($0.id) }
  }
}

extension PanelController {
  /// The check card for the selected installed wallpaper on the target display, or nil with none.
  ///
  /// A result the store holds for another wallpaper or display (it is dropped the next time
  /// `reconcileInspectorContext()` runs) is not shown.
  var compatibilityState: CompatibilityState? {
    startInspectorContextObservation()
    guard let context = compatibilityContext() else { return nil }
    let current = compatibility.context == context
    let settings = store.settingsSnapshot
    let display = settings.displays.first { $0.displayId == context.displayID }
    let physicalID = ResolvedDisplayTitles.liveDisplayID(
      context.displayID, title: display?.title ?? "")
    var report: (backend: String, reason: String?)?
    var failure: SceneFailureReport?
    if let video = settings.videoBackends.first(where: {
      $0.wallpaperId == context.wallpaperID && $0.displayId == physicalID
    }) {
      report = (video.backend, video.fallbackReason)
    } else if let scene = settings.sceneRenderers.first(where: {
      $0.wallpaperId == context.wallpaperID && $0.displayId == physicalID
    }) {
      report = (scene.backend, nil)
      failure = scene.failureStage.map {
        SceneFailureReport(stage: SceneFailureStage(name: $0), reason: scene.failureReason)
      }
    }
    return CompatibilityState(
      wallpaperID: context.wallpaperID, displayID: context.displayID, kind: context.kind,
      isChecking: current && compatibility.checking, checks: current ? compatibility.checks : [],
      backend: report?.backend, fallbackReason: report?.reason, failure: failure,
      canCheck: context.targetAvailable)
  }

  /// `compatibilityCheck`: reads the wallpaper's files again and re-runs the checks. Leaves the banner
  /// alone and does not wait for the command queue. A card for another wallpaper or display than
  /// the ones selected and targeted now is refused, as is a target that cannot be checked (a mirror
  /// follows its source, a disabled display plays nothing).
  func checkCompatibility(_ wallpaperID: String, display displayID: String) async throws {
    try await run(.immediate) {
      let id = try installedWallpaperID(wallpaperID)
      guard store.wallpaperOptionsSnapshot?.wallpaperId == id else {
        throw WallpaperActionError(
          message: L("Wallpaper settings are unavailable. Refresh Library and retry."))
      }
      guard id == store.appSnapshot.selectedWallpaperId,
        displayID == navigation.targetDisplayID,
        let context = compatibilityContext(),
        context.wallpaperID == id, context.displayID == displayID,
        context.targetAvailable
      else { throw InvalidControlValue() }
      await compatibility.check(context, retry: true)
    }
  }

  /// What the check is certified against: the selected installed wallpaper on the target display, at
  /// the frame rate it would really get. Native admission is a mirror-group decision, so the rate
  /// is lowered by every enabled mirror of the target and by the global frame-rate cap: a 60 FPS
  /// source must not be certified when a 30 FPS mirror makes the whole group fall back.
  func compatibilityContext() -> WallpaperCompatibilityContext? {
    guard let id = store.appSnapshot.selectedWallpaperId,
      let entry = store.librarySnapshot.wallpapers.first(where: { $0.id == id })
    else { return nil }
    let settings = store.settingsSnapshot
    let displayID = navigation.targetDisplayID
    let display = settings.displays.first { $0.displayId == displayID }
    let available = display?.enabled == true && display?.mode == .standalone
    let options = store.wallpaperOptionsSnapshot.flatMap { $0.wallpaperId == id ? $0 : nil }
    let configuration = options?.displayConfigurations.first { $0.displayId == displayID }
    var fps = min(configuration?.targetFps ?? display?.targetFps ?? 0, display?.maxFps ?? 0)
    for mirror in settings.displays
    where mirror.enabled && mirror.mode == .mirror && mirror.selectedMirrorTarget == displayID {
      fps = min(fps, min(mirror.targetFps, mirror.maxFps))
    }
    if let cap = settings.frameRateCap { fps = min(fps, max(1, cap)) }
    let kind: WallpaperCompatibilityContext.Kind
    switch entry.kind {
    case .projectScene: kind = .scene
    case .video: kind = .video
    case .webpage: kind = .web
    case .unknown: kind = .unknown
    }
    // Reading the configured path is cheap; selecting and probing a usable assets folder happens
    // on the service actor, not through ClientPaths.assetsURL here.
    let assetsConfiguration =
      ProcessInfo.processInfo.environment["WALLPAPER_MACHINE_ASSETS_ROOT"]
      ?? ClientPreferences.defaults.string(forKey: "WallpaperMachineAssetsPath") ?? ""
    return WallpaperCompatibilityContext(
      wallpaperID: id, displayID: displayID, kind: kind, supported: entry.supported,
      targetFPS: fps, targetAvailable: available && options != nil && fps > 0,
      libraryRevision: store.libraryRefreshRevision, assetsConfiguration: assetsConfiguration)
  }
}
