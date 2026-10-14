import Foundation

@MainActor
extension WebPanelController {
  func hostStatesSnapshot() -> [[String: Any]] {
    let titles = displayTitles.resolved()
    return store.hostWallpaperStates.values.sorted { $0.key < $1.key }.map { state in
      let display = store.monitorInformationSnapshot.rows.first {
        ResolvedDisplayTitles.liveDisplayID($0.displayId, title: $0.title) == state.displayID
      }
      return [
        "wallpaperID": state.wallpaperID, "displayID": String(state.displayID),
        "displayTitle": display.map { titles.title($0.title, displayId: $0.displayId) } ?? String(state.displayID),
        "kind": state.kind.rawValue, "phase": state.phase.rawValue,
        "message": state.message as Any? ?? NSNull(),
        "canRetry": state.kind == .web && state.phase == .failed && state.canRetry && store.retryHostWallpaper != nil,
      ]
    }
  }

  /// The wallpapers the load journal held back, each with the sentence the page shows beside its
  /// Try again button. The sentence is worded here so the page never assembles a localized one.
  func heldWallpapersSnapshot() -> [[String: Any]] {
    store.heldWallpaperIDs.map { id in
      let title = store.librarySnapshot.wallpapers.first { $0.id == id }?.title ?? id
      return ["id": id, "title": title, "message": Self.heldWallpaperMessage(title: title)]
    }
  }

  static func heldWallpaperMessage(title: String) -> String {
    String(
      localized:
        "“\(title)” was not restored: WallpaperMachine quit unexpectedly twice in a row while loading it. Nothing was deleted."
    )
  }

  /// The one-time prompt the page should show now, if any (`SupportPromptStore`). Without a
  /// telemetry service there is nothing to offer, so that prompt never comes up.
  func pendingPrompt() -> SupportPromptStore.Prompt? {
    store.supportPrompt?.pendingPrompt(
      welcomeSeen: welcomeSeen, telemetryOn: store.telemetry?.isEnabled ?? true)
  }

  /// Register native dependencies without materializing a page payload while hidden.
  func trackSnapshotDependencies() {
    _ = store.appSnapshot
    _ = pendingPrompt()
    _ = store.telemetry?.preferences.state
    _ = store.librarySnapshot
    _ = store.history.entries
    _ = store.libraryRefreshRevision
    _ = store.wallpaperOptionsSnapshot
    _ = store.monitorInformationSnapshot
    _ = store.settingsSnapshot
    _ = store.snapshotRevision
    _ = store.libraryLoadState
    _ = store.activatingWallpaperID
    _ = store.applyingWallpaperID
    _ = store.commands.isBusy
    _ = store.commands.waiting
    _ = store.latestBridgeErrorMessage
    _ = store.latestBridgeErrorRevision
    _ = store.hostWallpaperStates
    _ = store.webWallpaperDeliveryRevision
    _ = imports.isBusy
    _ = imports.status
    _ = imports.report
    _ = imports.failure
    let lock = store.lockScreenWallpaper
    _ = lock?.isRequested
    _ = lock?.isBusy
    _ = lock?.status
    _ = lock?.errorMessage
    _ = lock?.screenSaverRequested
    _ = lock?.screenSaverEnabled
    _ = lock?.screenSaverStatus
    _ = lock?.screenSaverError
    _ = workshop.searchText
    _ = workshop.kind
    _ = workshop.sort
    _ = workshop.tags
    _ = workshop.excludedTags
    _ = workshop.items
    _ = workshop.selectedItem
    _ = workshop.page
    _ = workshop.totalPages
    _ = workshop.totalCount
    _ = workshop.isLoading
    _ = workshop.hasLoaded
    _ = workshop.isDegraded
    _ = workshop.errorMessage
    _ = workshop.sceneAssetsReady
    _ = workshop.sceneAssetsURL
    _ = workshop.sceneAssetsFailure
    _ = workshop.downloadRequests
    _ = workshop.applyIntents
    _ = workshop.applyNotes
    _ = workshop.downloadPersistenceError
    _ = workshop.username
    _ = workshop.suggestedAccount
    let updates = workshop.updates
    _ = updates.available
    _ = updates.isChecking
    _ = updates.lastChecked
    _ = updates.errorMessage
    _ = updates.checksAutomatically
    let setup = workshop.steamCMDSetup
    _ = setup.state
    _ = setup.isBusy
    _ = setup.selectedRuntime
    _ = setup.retainedCandidateURL
    let downloader = workshop.downloader
    trackPixivDependencies()
    trackBackupDependencies()
    trackCompatibilityDependencies()
    trackLetterboxDependencies()
    _ = updater.state
    _ = downloader.savedAccount
    _ = downloader.rememberSessionWhileRunning
    _ = downloader.errorMessage
    _ = downloader.sessionConflictDetected
    for job in downloader.downloads {
      _ = job.status
      _ = job.phase
      _ = job.errorMessage
      _ = job.progress
      _ = job.bytesReceived
      _ = job.bytesExpected
      _ = job.bytesPerSecond
      _ = job.isPending
      _ = job.isQueued
      _ = job.isPaused
      _ = job.isCancelled
      let worker = job.worker
      _ = worker.steamGuardChallenge
      _ = worker.isAuthenticating
      _ = worker.errorMessage
      _ = worker.prompt
      _ = worker.sessionWarning
      _ = worker.wallpaperEngineOwnership
    }
  }

  private func trackPixivDependencies() {
    _ = pixiv.query
    _ = pixiv.committedQuery
    _ = pixiv.works
    _ = pixiv.hiddenCount
    _ = pixiv.page
    _ = pixiv.totalPages
    _ = pixiv.totalCount
    _ = pixiv.isLoading
    _ = pixiv.hasLoaded
    _ = pixiv.errorMessage
    _ = pixiv.selectedWork
    _ = pixiv.selectedPage
    _ = pixiv.selectedPages
    _ = pixiv.isSignedIn
    _ = pixiv.isSigningIn
    _ = pixiv.account
    _ = pixiv.accountMessage
    _ = pixiv.downloads.persistenceError
    for job in pixiv.downloads.downloads {
      _ = job.status
      _ = job.bytesReceived
      _ = job.bytesExpected
    }
  }

  /// A dismissal suppresses exactly the message the user dismissed; a later,
  /// different failure surfaces again, and clearing the source re-arms it.
  var libraryFailureMessage: String? {
    if case .failed(let message) = store.libraryLoadState { message } else { nil }
  }

  var downloadError: String? {
    let message = workshop.downloader.errorMessage ?? workshop.downloadPersistenceError ?? pixiv.downloads.persistenceError
    return message == dismissedDownloadError ? nil : message
  }

  func reconcileDismissedErrors() {
    if libraryFailureMessage == nil { dismissedLibraryError = nil }
    if workshop.downloader.errorMessage == nil { dismissedDownloadError = nil }
  }

  /// Width the page keeps clear for the traffic lights when the window draws them over
  /// the page's top bar. Zero when the page is windowless or the lights are hidden.
  var windowControlsInset: Double {
    guard let window = webView?.window,
      window.styleMask.contains(.fullSizeContentView),
      !window.styleMask.contains(.fullScreen),
      window.titleVisibility == .hidden,
      let zoom = window.standardWindowButton(.zoomButton), let superview = zoom.superview,
      !zoom.isHidden
    else { return 0 }
    return max(0, superview.convert(zoom.frame, to: nil).maxX.rounded(.up))
  }

  /// What each `file` / `directory` property of this wallpaper currently points at.
  ///
  /// Measuring the chosen folder is a directory read, and the page re-renders from a
  /// snapshot many times a second, so a measurement is kept until the chosen path
  /// changes. The panel closing throws the cache away and the next snapshot measures
  /// once more, which is why the row survives a reopen without the panel holding the
  /// wallpaper's staged files open.
  func measuredAssets(for options: BridgeWallpaperOptionsSnapshot)
    -> [String: WebPanelPropertyAsset]
  {
    var measured: [String: WebPanelPropertyAsset] = [:]
    for property in options.properties
    where property.enabled && (property.kind == .file || property.kind == .directory) {
      guard case .string(let path) = property.value, !path.isEmpty else { continue }
      if let cached = propertyAssets[options.wallpaperId]?[property.id], cached.path == path {
        measured[property.id] = cached
        continue
      }
      let asset = Self.measure(
        path: path, directory: property.kind == .directory,
        filter: Self.assetFilter(property.fileFilter))
      propertyAssets[options.wallpaperId, default: [:]][property.id] = asset
      measured[property.id] = asset
    }
    return measured
  }

  /// Counts what the chosen folder offers the importer: first level only, matching
  /// extensions only, and one past the limit so exceeding it can be reported rather
  /// than silently dropping the remainder. A folder that cannot be read counts nothing,
  /// which the page reports as unreadable instead of as empty.
  ///
  /// The three screens beyond the extension — hidden entries, anything that is not a
  /// regular file, anything unreadable — are the ones `UserAssetStore` applies, so this
  /// count cannot come out above what staging would take. A folder named `photos.png`
  /// is the case a bare extension test gets wrong.
  static func measure(path: String, directory: Bool, filter: UserAssetFilter)
    -> WebPanelPropertyAsset
  {
    let url = URL(fileURLWithPath: path)
    var asset = WebPanelPropertyAsset(path: path, name: url.lastPathComponent)
    guard directory else { return asset }
    guard
      let entries = try? FileManager.default.contentsOfDirectory(
        at: url, includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles])
    else { return asset }
    let allowed = filter.allowedExtensions
    let limit = UserAssetStore.defaultDirectoryFileLimit
    var matches = 0
    for entry in entries where allowed.contains(entry.pathExtension.lowercased()) {
      guard (try? entry.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
        FileManager.default.isReadableFile(atPath: entry.path)
      else { continue }
      guard matches < limit else {
        asset.truncated = true
        break
      }
      matches += 1
    }
    asset.matches = matches
    return asset
  }

  struct LibrarySectionKey: Equatable {
    var content: UInt64
    var refresh: UInt64
    var metrics: UInt64
    var covers: UInt64
    var updates: UInt64
    var energy: UInt64
    var target: String
    var language: String
  }

  struct LibrarySection {
    var key: LibrarySectionKey
    var revision: String
    var wallpapers: [[String: Any]]
  }

  private func librarySection() -> LibrarySection {
    let key = LibrarySectionKey(content: store.libraryPresentationRevision,
      refresh: store.libraryRefreshRevision, metrics: libraryMetrics.contentRevision,
      covers: libraryCovers.contentRevision, updates: workshop.updates.availableRevision,
      energy: store.wallpaperEnergyRatings?.revision ?? 0,
      target: navigation.targetDisplayID, language: appLanguage.effective.tag)
    if let cached = librarySectionCache, cached.key == key { return cached }
    let null = NSNull()
    let revision = store.libraryRefreshRevision
    var previewFiles: [String: URL] = [:]
    for entry in store.librarySnapshot.wallpapers {
      if let path = entry.previewPath { previewFiles[entry.id] = URL(fileURLWithPath: path) }
    }
    // Read in the background; the section is rebuilt once a stamp is new or moved.
    let covers = libraryCovers.stamps(for: previewFiles, revision: revision)
    let metrics = libraryMetrics.metrics(
      for: store.librarySnapshot.wallpapers.map(\.id), revision: revision)
    let updates = workshop.updates.available
    let wallpapers: [[String: Any]] = store.librarySnapshot.wallpapers.map { entry in
      var preview: Any = null
      var thumbnail: Any = null
      var animated: Any = null
      if let file = previewFiles[entry.id] {
        preview = Self.libraryAddress(host: "preview", id: entry.id) as Any? ?? null
        // Tiles show the cached still, asked for under the preview file's stamp so that it is
        // asked for again only when the file changed; only a preview that can move offers the file
        // itself to play. Until the stamp is read there is no cover yet, and the page shows
        // nothing rather than the full-size preview.
        if let stamp = covers[entry.id] {
          thumbnail = Self.libraryAddress(host: "library-thumbnail", id: entry.id, stamp: stamp) as Any? ?? null
        }
        if Self.previewAnimates(file) { animated = preview }
      }
      return [
        "id": entry.id, "title": entry.title, "kind": Self.kind(entry.kind), "preview": preview,
        "thumbnail": thumbnail, "coverPending": previewFiles[entry.id] != nil && covers[entry.id] == nil,
        "animated": animated,
        "active": store.isWallpaperActive(id: entry.id, displayId: navigation.targetDisplayID),
        "supported": entry.supported,
        // Folder size, date added, staff approval and the manifest's Workshop-style tags
        // arrive once measured; null sorts last on the page.
        "tags": metrics[entry.id]?.tags ?? [],
        "approved": metrics[entry.id]?.approved ?? false,
        "size": metrics[entry.id]?.size as Any? ?? null,
        "addedAt": metrics[entry.id]?.addedAt.map { $0.timeIntervalSince1970 * 1000 } as Any? ?? null,
        // Measured in the background while the wallpaper played alone; null until rated.
        "energy": store.wallpaperEnergyRatings?.snapshot(for: entry.id, kind: entry.kind) as Any?
          ?? null,
        // When the Workshop has a newer version: when its author last changed it.
        "updateAvailable": updates[entry.id] != nil,
        "updatedAt": updates[entry.id]?.timeUpdated.map { $0.timeIntervalSince1970 * 1000 } as Any? ?? null,
      ]
    }
    // The same files are served whole as the preview and as the small cover tiles show.
    assets.previews = previewFiles
    assets.libraryThumbnails = previewFiles
    let result = LibrarySection(key: key, revision: UUID().uuidString, wallpapers: wallpapers)
    librarySectionCache = result
    return result
  }

  func snapshot() -> [String: Any] {
    let settings = store.settingsSnapshot
    let setup = workshop.steamCMDSetup
    let lock = store.lockScreenWallpaper
    let null = NSNull()
    let library = librarySection()
    let wallpapers = library.wallpapers
    var thumbnails: [String: URL] = [:]
    for item in workshop.items + workshop.downloader.downloads.compactMap(\.item) + workshop.downloadRequests.compactMap(\.item)
    where item.previewURL?.scheme == "https" {
      thumbnails[item.id] = item.previewURL
    }
    assets.thumbnails = thumbnails
    var pixivThumbnails: [String: URL] = [:]
    let pixivWorks = pixiv.works + [pixiv.selectedWork].compactMap { $0 } + pixiv.downloads.downloads.map(\.work)
    for work in pixivWorks { pixivThumbnails[work.id] = work.thumbnailURL }
    if let work = pixiv.selectedWork {
      for page in pixiv.selectedPageList ?? [] { pixivThumbnails["\(work.id)-p\(page.index)"] = page.previewURL }
    }
    assets.pixivThumbnails = pixivThumbnails
    var propertyImages: [String: URL] = [:]
    for property in store.wallpaperOptionsSnapshot?.properties ?? [] where property.enabled {
      for image in PropertyImageCache.sources(in: property.labelHtml).values {
        propertyImages[PropertyImageCache.key(for: image)] = image
      }
    }
    assets.propertyImages = propertyImages
    let titles = displayTitles.resolved()
    let displays: [[String: Any]] = settings.displays.map { display in
      let active = store.monitorInformationSnapshot.rows.first { $0.displayId == display.displayId }
      let wallpaperOptions = active.flatMap { row in
        store.wallpaperOptionsSnapshot?.wallpaperId == row.wallpaperId
          ? store.wallpaperOptionsSnapshot
          : (displayOptionsRevision == store.snapshotRevision ? displayOptions[row.wallpaperId] : nil)
      }
      let config =
        display.mode == .standalone
        ? wallpaperOptions?.displayConfigurations.first { $0.displayId == display.displayId } : nil
      return [
        "id": display.displayId, "title": titles.title(display.title, displayId: display.displayId),
        "enabled": display.enabled, "mode": display.mode == .mirror ? "mirror" : "standalone",
        "mirrorTarget": display.selectedMirrorTarget as Any? ?? null,
        "mirrorTargets": display.mirrorTargets.map { id in
          let title = settings.displays.first { $0.displayId == id }?.title ?? id
          return ["id": id, "title": titles.title(title, displayId: id)]
        }, "scalingMode": Self.scaling(config?.scalingMode ?? display.scalingMode),
        "scalingFactor": config?.scalingFactor ?? display.scalingFactor,
        "fps": config?.targetFps ?? display.targetFps, "maxFps": display.maxFps,
        "volume": config == nil ? display.volume : wallpaperOptions?.volume ?? display.volume,
        "muted": config == nil ? display.muted : wallpaperOptions?.muted ?? display.muted,
        "wallpaperID": active?.wallpaperId as Any? ?? null,
      ]
    }
    var setupError: String?
    var canApprove = false
    var setupProgress: Double?
    let setupStatus: String
    switch setup.state {
    case .idle: setupStatus = String(localized: "Not installed")
    case .checking: setupStatus = String(localized: "Checking SteamCMD…")
    case .downloading(let received, let expected):
      setupStatus = String(localized: "Downloading SteamCMD…")
      if let expected, expected > 0 { setupProgress = min(1, Double(received) / Double(expected)) }
    case .extracting: setupStatus = String(localized: "Extracting SteamCMD…")
    case .validating: setupStatus = String(localized: "Validating SteamCMD…")
    case .committing: setupStatus = String(localized: "Saving installation…")
    case .ready: setupStatus = String(localized: "Ready")
    case .cancelled: setupStatus = String(localized: "Installation cancelled")
    case .failed(let issue):
      setupStatus = String(localized: "Setup needs attention")
      setupError = issue.detail
      canApprove = issue.kind == .securityApprovalRequired && setup.retainedCandidateURL != nil
    }
    let downloads: [[String: Any]] = workshop.downloader.downloads.map { job in
      let worker = job.worker
      let challenge: String?
      switch worker.steamGuardChallenge {
      case .mobileApproval: challenge = "mobileApproval"
      case .authenticatorCode: challenge = "authenticatorCode"
      case .emailCode: challenge = "emailCode"
      case .none: challenge = nil
      }
      return [
        "id": job.id, "wallpaperID": job.item?.id as Any? ?? null,
        "title": job.item?.title ?? Self.itemlessTitle(job.id), "status": job.status,
        "preview": job.item?.previewURL?.absoluteString as Any? ?? null,
        "thumbnail": job.item.flatMap(Self.thumbnailAddress) as Any? ?? null, "account": job.account,
        "phase": job.phase?.rawValue as Any? ?? null,
        "progress": job.progress as Any? ?? null, "pending": job.isPending, "queued": job.isQueued, "paused": job.isPaused, "signInOnly": job.isSignIn,
        "bytesReceived": job.bytesReceived as Any? ?? null,
        "bytesExpected": job.bytesExpected as Any? ?? null,
        "bytesPerSecond": job.bytesPerSecond as Any? ?? null,
        "secondsRemaining": job.secondsRemaining as Any? ?? null,
        // The sign-in handoff has no prompt yet; the dialog must stay open through it.
        "authenticating": job.isPending && !job.isQueued && worker.isAuthenticating,
        "cancelled": job.isCancelled,
        "error": job.errorMessage as Any? ?? null,
        "prompt": worker.prompt?.rawValue as Any? ?? null,
        "securePrompt": worker.prompt == .password, "challenge": challenge as Any? ?? null,
        "warning": worker.sessionWarning as Any? ?? null,
        "wallpaperEngineOwnership": worker.wallpaperEngineOwnership.rawValue,
        "applyOnArrival": workshop.appliesOnArrival(job.id),
      ]
    }
    let downloadRequests: [[String: Any]] = workshop.downloadRequests.map { request in
      [
        "id": request.id, "wallpaperID": request.item?.id as Any? ?? null,
        "title": request.item?.title ?? Self.itemlessTitle(request.id),
        "preview": request.item?.previewURL?.absoluteString as Any? ?? null,
        "thumbnail": request.item.flatMap(Self.thumbnailAddress) as Any? ?? null,
        "account": request.account, "rememberSession": request.rememberSession,
        "stage": workshop.stage(for: request).rawValue, "paused": request.isPaused,
        "applyOnArrival": workshop.appliesOnArrival(request.id),
      ]
    }
    let loading: Bool
    let libraryError: String?
    switch store.libraryLoadState {
    case .loading:
      loading = true
      libraryError = nil
    case .loaded:
      loading = false
      libraryError = nil
    case .failed(let message):
      loading = false
      libraryError = message
    }
    let page: String
    switch navigation.selection {
    case .workshop: page = "discover"
    case .pixiv: page = "pixiv"
    case .settings, .display: page = "settings"
    default: page = "installed"
    }
    let videoBackends: [[String: Any]] = settings.videoBackends.map { report in
      [
        "displayId": Int(report.displayId), "displayName": report.displayName,
        "wallpaperId": report.wallpaperId, "wallpaperTitle": report.wallpaperTitle,
        "backend": report.backend,
        "fallbackReason": report.fallbackReason as Any? ?? null,
      ]
    }
    // Live per-scene read-backs, rebuilt with every snapshot. An empty array
    // is "no scene wallpaper is running"; a row whose mode or backend reads
    // `unknown` is "one is running and could not be read". The page must keep
    // those apart, so neither is padded here into something more definite.
    let sceneUpdateModes: [[String: Any]] = settings.sceneUpdateModes.map { report in
      [
        "displayId": Int(report.displayId), "display": report.displayName,
        "wallpaperId": report.wallpaperId, "wallpaperTitle": report.wallpaperTitle,
        "mode": report.mode, "reasons": report.reasons,
      ]
    }
    let sceneRenderers: [[String: Any]] = settings.sceneRenderers.map { report in
      [
        "displayId": Int(report.displayId), "display": report.displayName,
        "wallpaperId": report.wallpaperId, "wallpaperTitle": report.wallpaperTitle,
        "backend": report.backend,
        "fallbackReason": report.fallbackReason as Any? ?? null,
        "videoPath": report.videoPath,
        "optimizationApplied": report.optimizationApplied as Any? ?? null,
      ]
    }
    // Each global shortcut the user can record, with why macOS refused it if it did.
    let hotKeyRows: [[String: Any]] = HotKeyAction.allCases.map { action in
      [
        "id": action.rawValue, "shortcut": hotKeys.bindings[action]?.label as Any? ?? null,
        "error": hotKeys.failures[action] as Any? ?? null,
      ]
    }
    // What Playback shows as in effect right now, beside the saved choices.
    let lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    let thermalState = Self.thermalState(ProcessInfo.processInfo.thermalState)
    // What the engine holds the frame rate to and why, so the page names the cause and does not
    // work the ceiling out again.
    let effectiveFrameRateCap: Any = settings.effectiveFrameRateCap.map { Int($0) } as Any? ?? null
    let qualityThrottle = Self.qualityThrottle(settings.qualityThrottle)
    let focusAction = FocusFilterState.shared.selection?.target.kind.rawValue
      ?? FocusFilterState.shared.action?.rawValue ?? "keepRunning"
    // The charge is null on a Mac without an internal battery, which is how the page knows to
    // leave the low-battery rows out.
    let playbackChoicesSnapshot: [String: Any] = [
      "lowBatteryAction": playback.lowBatteryAction.rawValue,
      "lowBatteryThreshold": playback.lowBatteryThreshold,
      "batteryPercent": BatteryReading.read()?.percent as Any? ?? null,
      "playOnlyOnActiveDisplay": playback.playsOnlyOnActiveDisplay,
      "wallpapersMuted": playback.wallpapersMuted,
      // The animated lock screen sets the desktop picture itself, so the choice waits for it.
      "writeDesktopPicture": playback.writesDesktopPicture,
      "desktopPictureLocked": lock?.locksDesktopPictureChoice ?? false,
    ]
    // The sections are built separately: as one literal, the Swift compiler on the
    // macOS 15 release runner gives up type-checking it in reasonable time.
    let settingsSnapshot: [String: Any] = [
      "launchAtLogin": settings.launchAtLoginEnabled,
      "launchAtLoginAvailable": settings.launchAtLoginAvailable,
      "launchAtLoginNeedsApproval": settings.launchAtLoginNeedsApproval,
      "verboseLogging": settings.verboseLogging,
      "videoBackend": settings.videoBackend, "videoBackends": videoBackends,
      "contentPacing": settings.contentPacingEnabled,
      "sharedVideoDecode": settings.sharedVideoDecodeEnabled,
      "sceneOptimization": settings.sceneOptimizationEnabled,
      "sceneOnDemand": settings.sceneOnDemandEnabled,
      "sceneVideoPlaneSampling": settings.sceneVideoPlaneSamplingEnabled,
      "sceneUpdateModes": sceneUpdateModes,
      "sceneRenderer": settings.sceneRenderer, "sceneRenderers": sceneRenderers,
      "sharedVideoDecodeSessions": Int(settings.sharedVideoDecodeSessions),
      "sharedVideoDecodeConsumers": Int(settings.sharedVideoDecodeConsumers),
      "renderScale": Double(settings.renderScale),
      "preferredRenderScale": Double(settings.preferredRenderScale),
      "renderScaleSupported": settings.renderScaleSupported,
      "batteryMode": Self.batteryMode(settings.batteryMode),
      "batteryRenderScale": Double(settings.batteryRenderScale),
      "batteryTargetFps": Int(settings.batteryTargetFps),
      "onBatteryPower": settings.onBatteryPower,
      "frameRateCap": settings.frameRateCap.map { Int($0) } as Any? ?? null,
      "frameRateCapMax": Self.frameRateCapMax(settings),
      "effectiveFrameRateCap": effectiveFrameRateCap, "qualityThrottle": qualityThrottle,
      "displaySleepAction": playback.displaySleepAction.rawValue,
      "otherAudioAction": playback.otherAudioAction.rawValue,
      "desktopCoveredAction": playback.desktopCoveredAction.rawValue,
      "lowPowerModeAction": playback.lowPowerModeAction.rawValue,
      "thermalAction": playback.thermalAction.rawValue,
      "lowPowerMode": lowPowerMode, "thermalState": thermalState, "focusAction": focusAction,
      "appRules": playback.appRules.map { rule in
        [
          "id": rule.id.uuidString,
          "name": rule.name,
          "bundleID": rule.bundleIdentifier,
          "condition": rule.condition.rawValue,
          "action": rule.action.rawValue,
        ]
      },
      "keepWindowsOnWallpaperClick": !DesktopClickRevealPreference.isEnabled,
      "refreshDesktopPicture": playback.refreshesDesktopPicturePeriodically,
      "hotkeys": hotKeyRows,
      "hideAfterActivating": hidesAfterActivating,
      "telemetry": store.telemetry?.isEnabled ?? false, "telemetryAvailable": store.telemetry != nil,
      "telemetryLastSent": store.telemetry?.lastSentAt.map { $0.timeIntervalSince1970 * 1000 } as Any? ?? null,
      "inspectWebWallpapers": WebWallpaperInspection.isEnabled(defaults: defaults),
      "livePropertyEdits": LivePropertyEditing.isEnabled(defaults: defaults),
      "lockScreenEnabled": lock?.isRequested ?? false, "lockScreenAvailable": lock != nil,
      "lockScreenBusy": lock?.isBusy ?? false, "lockScreenStatus": lock?.status
        ?? (LockScreenConfiguration.isSupportedBySystem
          ? String(localized: "Unavailable") : String(localized: "Requires macOS 26 or later")),
      "lockScreenError": lock?.errorMessage as Any? ?? null,
      "screenSaverEnabled": lock?.screenSaverRequested ?? false, "screenSaverAvailable": lock != nil,
      "screenSaverBusy": lock?.isBusy ?? false, "screenSaverStatus": lock?.screenSaverStatus
        ?? (LockScreenConfiguration.isSupportedBySystem
          ? String(localized: "Unavailable") : String(localized: "Requires macOS 26 or later")),
      "screenSaverError": lock?.screenSaverError as Any? ?? null,
      "sceneAssetsReady": workshop.sceneAssetsReady,
      "sceneAssetsWarning": workshop.sceneAssetsFailure as Any? ?? null,
      "concurrentDownloads": workshop.downloader.maximumConcurrentDownloads,
      "concurrentDownloadsMax": WorkshopDownloadManager.concurrentDownloadRange.upperBound,
      "assetsPath": workshop.sceneAssetsURL.path, "libraryPath": ClientPaths.libraryURL.path,
      "shaderCacheBytes": settings.storage.shaderCacheSizeBytes,
      "logBytes": settings.storage.logs.activeFileSizeBytes,
      "userAssetsPath": settings.userAssetsPath,
      "userAssetsReleasedBytes": userAssetsReleasedBytes as Any? ?? null,
      "bridgeVersion": settings.bridgeVersion, "coreVersion": settings.coreVersion,
      "shaderVersion": settings.shaderPipelineVersion, "gitSha": settings.gitSha,
    ]
    // The source on show, named as Steam named it once its first page arrived.
    let shownSource = workshop.source
    let sourceName = (workshop.committedQuery?.source == shownSource ? workshop.sourceTitle : nil) ?? shownSource.name
    let workshopSource: [String: Any] = [
      "key": shownSource.key, "id": shownSource.id as Any? ?? null, "name": sourceName as Any? ?? null,
      "searchable": shownSource.isSearchable, "canGoBack": !workshop.sourceHistory.isEmpty,
    ]
    let workshopSnapshot: [String: Any] = [
      "text": workshop.searchText, "kind": workshop.kind.rawValue, "sort": workshop.sort.rawValue,
      "tags": workshop.tags, "excludedTags": workshop.excludedTags,
      "items": workshop.items.map(Self.workshopItem),
      "selectedID": workshop.selectedItem?.id as Any? ?? null, "page": workshop.page,
      "totalPages": workshop.totalPages, "totalCount": workshop.totalCount,
      "reachable": workshop.reachableCount, "pageSize": WorkshopStore.pageSize,
      "maxPages": WorkshopStore.maxPages,
      "loading": workshop.isLoading, "loaded": workshop.hasLoaded,
      "error": workshop.errorMessage as Any? ?? null,
      // The grid shows the one item a pasted link or id named, which no filter applies to.
      "lookup": workshop.committedQuery?.itemID != nil,
      // The list was found from the links on a Steam page whose markup changed: it may be incomplete.
      "degraded": workshop.isDegraded,
      "source": workshopSource,
      // The Steam page listing what is on show, for Open on Steam.
      "steamURL": workshop.browseURL.absoluteString,
      "steamSignedIn": workshop.steamWebSession != nil, "steamSigningIn": workshop.isSigningInToSteamWeb,
    ]
    // Every configured display's playlist, with when it next changes on its own.
    var playlistSnapshot: [String: Any] = [:]
    for (display, playlist) in playlists.playlists {
      let next = playlists.nextChange[display].map { $0.timeIntervalSince1970 * 1000 } as Any? ?? null
      var value = Self.organizationPlaylistSnapshot(playlist)
      value["nextChange"] = next
      // The playlist waits because the user removed this display's wallpaper.
      value["held"] = playlists.holds[display] != nil
      value["skipped"] = (playlists.skipped[display] ?? [:]).sorted { $0.key < $1.key }.map { id, failure in
        ["id": id, "message": failure.message,
         "retryAfter": failure.retryAfter.timeIntervalSince1970 * 1000] as [String: Any]
      }
      playlistSnapshot[display] = value
    }
    let updateCheck = workshop.updates
    let updatesSnapshot: [String: Any] = [
      "checking": updateCheck.isChecking, "count": updateCheck.available.count,
      "lastChecked": updateCheck.lastChecked.map { $0.timeIntervalSince1970 * 1000 } as Any? ?? null,
      "error": updateCheck.errorMessage as Any? ?? null, "automatic": updateCheck.checksAutomatically,
    ]
    let setupSnapshot: [String: Any] = [
      "status": setupStatus, "busy": setup.isBusy, "ready": setup.selectedRuntime != nil,
      "error": setupError as Any? ?? null, "canApprove": canApprove,
      "candidatePath": setup.retainedCandidateURL?.path as Any? ?? null,
      "canCancel": setup.isBusy && setup.state != .committing,
      "progress": setupProgress as Any? ?? null,
    ]
    let error: String? = actionError ?? imports.failure
      ?? (libraryError == dismissedLibraryError ? nil : libraryError)
      ?? (store.latestBridgeErrorRevision > dismissedErrorRevision
        ? store.latestBridgeErrorMessage : nil)
    let options: Any? = store.wallpaperOptionsSnapshot.map { value in
      // The displays macOS's own video player draws this wallpaper on, which cannot be moved.
      let nativePlayerDisplays = Set(
        settings.videoBackends.filter { $0.wallpaperId == value.wallpaperId && $0.backend == "native" }
          .map(\.displayId))
      return Self.options(
        value, titles: titles, assets: measuredAssets(for: value),
        errors: propertyPathErrors[value.wallpaperId] ?? [:],
        delivery: store.webWallpaperDeliveryStatus?(), sceneMedia: store.sceneMediaAvailability?(),
        nativePlayerDisplays: nativePlayerDisplays)
    }
    return [
      "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        ?? "",
      "repositoryURL": AppUpdateConfiguration.repositoryURL.absoluteString,
      "windowControlsInset": windowControlsInset,
      "page": page, "targetDisplayID": navigation.targetDisplayID,
      "settingsSection": navigation.settingsSection.rawValue,
      "settingsSectionToken": Int(navigation.settingsSectionToken),
      "theme": theme.preferences.snapshot,
      "language": appLanguage.snapshot,
      "selectedID": store.appSnapshot.selectedWallpaperId as Any? ?? null,
      "paused": store.appSnapshot.playbackState == .paused,
      "busy": store.commands.isBusy || store.activatingWallpaperID != nil
        || store.applyingWallpaperID != nil,
      // Tiles mark the wallpaper being switched to and any queued behind it; waiting is shown
      // as progress, never as an error.
      "applyingID": (store.activatingWallpaperID ?? store.applyingWallpaperID) as Any? ?? null,
      "queuedApplyIDs": store.waitingActivationIDs,
      "error": error as Any? ?? null,
      "libraryLoading": loading, "favorites": favoriteIDs.sorted(), "wallpapers": wallpapers,
      "history": [
        "recentIDs": store.history.recent(on: navigation.targetDisplayID,
          available: Set(store.librarySnapshot.wallpapers.filter(\.supported).map(\.id))),
        "previousID": store.previousWallpaperID(displayId: navigation.targetDisplayID) as Any? ?? null,
      ],
      "previewAvailable": store.openPreview != nil,
      "hostStates": hostStatesSnapshot(),
      "held": heldWallpapersSnapshot(),
      "libraryRevision": library.revision,
      "filtersCollapsed": filtersCollapsed,
      "welcomeSeen": welcomeSeen,
      "pendingPrompt": (presentationAllowsUpdates() ? pendingPrompt()?.rawValue : nil) as Any? ?? null,
      "dragSelectLearned": dragSelectLearned,
      "displays": displays,
      "playlists": playlistSnapshot, "playlistIntervals": DisplayPlaylist.intervals,
      "playlistIntervalRange": [DisplayPlaylist.intervalRange.lowerBound, DisplayPlaylist.intervalRange.upperBound],
      "automation": wallpaperAutomationSnapshot(),
      "displayLayouts": displayLayoutsSnapshot(),
      "libraryOrganization": libraryOrganizationSnapshot(),
      "wallpaperPresets": wallpaperPresetsSnapshot(),
      "backup": backupSnapshot(),
      "imagePlacement": imagePlacementSnapshot(),
      "wallpaperCompatibility": compatibilitySnapshot()["wallpaperCompatibility"] ?? null,
      "videoLetterbox": letterboxSnapshot() as Any? ?? null,
      "options": options ?? null,
      "settings": settingsSnapshot.merging(playbackChoicesSnapshot) { _, new in new },
      "workshop": workshopSnapshot, "workshopUpdates": updatesSnapshot,
      "pixiv": pixivSnapshot(),
      "setup": setupSnapshot,
      "downloads": downloads, "downloadRequests": downloadRequests,
      // Why a wallpaper that arrived through Download and apply was left alone, by item id.
      "applyNotes": workshop.applyNotes,
      "downloadSlots": workshop.downloader.slotLimit,
      "account": workshop.suggestedAccount,
      "savedAccount": workshop.downloader.savedAccount as Any? ?? null,
      "rememberSession": workshop.downloader.rememberSessionWhileRunning ?? remembersSession,
      "downloadError": downloadError as Any? ?? null,
      "update": Self.update(updater.state, notes: updater.releaseNotes, rateLimitedUntil: updater.rateLimitedUntil),
      "import": [
        "busy": imports.isBusy, "status": imports.status,
        "report": imports.report.map { report -> [String: Any] in
          [
            "imported": report.importedIDs.count, "skipped": report.skipped.count,
            "failures": report.failures, "cancelled": report.cancelled,
          ]
        } as Any? ?? null,
      ],
    ]
  }

  static func update(_ state: AppUpdateState, notes: ReleaseNotes? = nil, rateLimitedUntil: Date? = nil) -> [String: Any] {
    let null = NSNull()
    let status: String
    let statusText: String
    var percent: Any = null
    var transferred: Any = null
    var total: Any = null
    switch state {
    case .unsupported:
      status = "unsupported"
      statusText = String(localized: "In-app updates are available only in installed builds.")
    case .idle:
      status = "idle"
      statusText = String(localized: "Updates not yet checked")
    case .checking:
      status = "checking"
      statusText = String(localized: "Checking for updates...")
    case .noRelease:
      status = "noRelease"
      statusText = String(localized: "No published update is available yet. You can keep using this version.")
    case .upToDate:
      status = "upToDate"
      statusText = String(localized: "Up to date")
    case .available(_, let version):
      status = "available"
      statusText = String(localized: "Version \(version) is available from GitHub Releases.")
    case .manual(_, let version):
      status = "manual"
      statusText = String(localized: "Version \(version) is available from GitHub Releases.")
    case .downloading(_, let version, let value, let done, let expected, _):
      status = "downloading"
      statusText = String(
        localized: "Downloading version \(version) — \(Int(value.rounded())) percent")
      percent = value
      transferred = done
      total = expected
    case .ready(_, let version):
      status = "ready"
      statusText = String(localized: "Version \(version) is ready. Restart the app to install it.")
    case .preparing:
      status = "preparing"
      statusText = String(localized: "Preparing update…")
    case .error(_, _, let code, _):
      status = "error"
      statusText = updateErrorText(code, rateLimitedUntil: rateLimitedUntil)
    }
    let action: Any
    let actionLabel: String
    let showsAction: Bool
    switch state {
    case .unsupported, .manual:
      action = null
      actionLabel = ""
      showsAction = false
    case .available:
      action = "downloadUpdate"
      actionLabel = String(localized: "Download Update")
      showsAction = true
    case .ready:
      action = "installUpdate"
      actionLabel = String(localized: "Restart and Install")
      showsAction = true
    case .preparing:
      action = "cancelUpdate"
      actionLabel = String(localized: "Cancel")
      showsAction = true
    case .error(_, .install, _, let version) where version != nil:
      action = "installUpdate"
      actionLabel = String(localized: "Retry installation")
      showsAction = true
    case .error:
      action = "checkForUpdates"
      actionLabel = String(localized: "Retry")
      showsAction = true
    case .upToDate, .noRelease:
      action = "checkForUpdates"
      actionLabel = String(localized: "Check Again")
      showsAction = true
    case .downloading(_, _, let value, _, _, _):
      action = "downloadUpdate"
      actionLabel = String(localized: "Downloading \(Int(value.rounded())) percent")
      showsAction = true
    case .checking, .idle:
      action = "checkForUpdates"
      actionLabel = String(localized: "Check for Updates")
      showsAction = true
    }
    let showsReleases: Bool
    switch state {
    case .unsupported, .manual, .error: showsReleases = true
    default: showsReleases = false
    }
    let showsReveal: Bool
    if case .ready = state { showsReveal = true } else { showsReveal = false }
    return [
      "status": status, "statusText": statusText, "action": action, "actionLabel": actionLabel,
      "showsAction": showsAction, "showsReleases": showsReleases, "showsReveal": showsReveal,
      "busy": state.isBusy, "percent": percent, "transferred": transferred, "total": total,
      "notesVersion": notes?.version as Any? ?? null,
      "notes": notes?.sections.map { section -> [String: Any] in
        ["title": section.title, "items": section.items]
      } ?? [],
      "footnote": String(
        localized:
          "Updates are checked against the latest published GitHub Release. Download and restart-install happen only after you confirm."
      ),
      "releasesLabel": String(localized: "Open GitHub Releases"),
      "revealLabel": String(localized: "Show in Finder"),
      "progressLabel": String(localized: "Update download progress"),
    ]
  }

  static func updateErrorText(_ code: AppUpdateErrorCode, rateLimitedUntil: Date? = nil) -> String {
    switch code {
    case .network:
      String(localized: "Couldn't reach GitHub Releases. Check your connection and try again.")
    case .rateLimited:
      if let rateLimitedUntil {
        String(
          localized:
            "GitHub's hourly limit for anonymous update checks is used up on this network (60 requests an hour, shared by every app and device on the same public IP). Try again after \(rateLimitedUntil.formatted(date: .omitted, time: .shortened))."
        )
      } else {
        String(
          localized:
            "GitHub's hourly limit for anonymous update checks is used up on this network (60 requests an hour, shared by every app and device on the same public IP). Try again later.")
      }
    case .configuration:
      String(localized: "The GitHub Release update metadata is unavailable.")
    case .verification:
      String(localized: "The update couldn't be verified, so it wasn't installed.")
    case .permission:
      String(localized: "The updater doesn't have permission to install this update.")
    case .unknown:
      String(localized: "The update couldn't be completed. Try again or install it from GitHub Releases.")
    }
  }

  static func kind(_ value: BridgeWallpaperKind) -> String {
    switch value {
    case .projectScene: "Scene"
    case .video: "Video"
    case .webpage: "Web"
    case .unknown: "Unknown"
    }
  }

  static func thermalState(_ state: ProcessInfo.ThermalState) -> String {
    switch state {
    case .nominal: "nominal"
    case .fair: "fair"
    case .serious: "serious"
    case .critical: "critical"
    @unknown default: "nominal"
    }
  }

  /// The names the page knows the reduced-quality reasons by, in the order the bridge reports them.
  static func qualityThrottle(_ causes: [BridgeQualityThrottleCause]) -> [String] {
    causes.map { cause in
      switch cause {
      case .lowPowerMode: "lowPowerMode"
      case .heat: "heat"
      case .lowBattery: "lowBattery"
      }
    }
  }

  static func scaling(_ value: BridgeScalingMode) -> String {
    switch value {
    case .none: "none"
    case .stretch: "stretch"
    case .match: "match"
    case .fill: "fill"
    }
  }

  static func batteryMode(_ mode: BridgeBatteryMode) -> String {
    switch mode {
    case .keepRunning: "keepRunning"
    case .reducedQuality: "reducedQuality"
    case .pause: "pause"
    }
  }

  static func frameRateCapMax(_ settings: BridgeSettingsSnapshot) -> Int {
    let highest = settings.displays.map(\.maxFps).max()
    guard let highest, highest >= 10 else { return 60 }
    return Int(highest)
  }

  static func options(
    _ value: BridgeWallpaperOptionsSnapshot, titles: ResolvedDisplayTitles,
    assets: [String: WebPanelPropertyAsset], errors: [String: String],
    delivery: WebWallpaperHost.DeliveryStatus? = nil,
    sceneMedia: SystemMediaAvailability? = nil,
    nativePlayerDisplays: Set<UInt32> = []
  ) -> [String: Any] {
    let null = NSNull()
    // Only a running host can say whether anything is being delivered. With no
    // host these keys are absent, which the panel reports as unknown. Emitting
    // null instead would make "available" and "cannot tell" the same value.
    var delivered: [String: Any] = [:]
    if let delivery {
        if let state = delivery.audioStates[value.wallpaperId] {
            delivered["audioDelivering"] = state == .delivering
            delivered["audioDeliveryState"] = state.rawValue
        } else {
            delivered["audioDeliveryState"] = "inactive"
        }
        delivered["mediaAvailable"] = delivery.mediaUnavailableReason == nil
        if let reason = delivery.mediaUnavailableReason {
            delivered["mediaUnavailableReason"] = reason
        }
    }
    if value.kind == .projectScene, let sceneMedia {
        switch sceneMedia {
        case .available:
            delivered["mediaAvailable"] = true
            delivered.removeValue(forKey: "mediaUnavailableReason")
        case .unavailable(let reason):
            delivered["mediaAvailable"] = false
            delivered["mediaUnavailableReason"] = reason
        }
    }
    if value.kind == .webpage {
      let controls = delivery?.audioOutputControls[value.wallpaperId]
      delivered["webAudioControl"] = [
        "volume": controls.map { $0.mediaVolume ? "mediaElements" : "unavailable" } ?? "unknown",
        "mute": controls.map { $0.pageMute ? "available" : "unavailable" } ?? "unknown",
      ]
    }
    var payload: [String: Any] = [
      "id": value.wallpaperId, "kind": kind(value.kind), "supported": value.supported,
      "dirty": value.dirty,
      "volume": value.volume, "muted": value.muted,
      "audioResponseEnabled": value.audioResponseEnabled,
      "mediaIntegrationEnabled": value.mediaIntegrationEnabled,
      // The page is not given a property a rule hides, yet its modified value still reaches the
      // wallpaper, so Restore all defaults needs to know of it. A chosen file keeps its own Clear.
      "hiddenModified": value.properties.contains {
        !$0.enabled && $0.dirty && $0.kind != .file && $0.kind != .directory
      },
      "displays": value.displayConfigurations.map { row -> [String: Any] in
        let physicalID = ResolvedDisplayTitles.liveDisplayID(row.displayId, title: row.title)
        return [
          "id": row.displayId, "title": titles.title(row.title, displayId: row.displayId),
          "enabled": row.enabled,
          "scalingMode": scaling(row.scalingMode), "scalingFactor": row.scalingFactor,
          // Where the wallpaper sits on this display, as fractions of the room around it. The
          // native video player draws a video centred whatever these say, so the page is told.
          "panX": row.framing.panX, "panY": row.framing.panY,
          "nativePlayer": physicalID.map { nativePlayerDisplays.contains($0) } ?? false,
          "fps": row.targetFps, "maxFps": row.maxFps,
        ]
      },
      // A property a visibility rule hides is not listed; the bridge still reports it.
      "properties": value.properties.filter(\.enabled).map { property -> [String: Any] in
        let kind: String
        switch property.kind {
        case .bool: kind = "boolean"
        case .texture: kind = "texture"
        case .file: kind = "file"
        case .directory: kind = "directory"
        case .slider: kind = "slider"
        case .combo: kind = "combo"
        case .color: kind = "color"
        case .textInput: kind = "textInput"
        case .group: kind = "group"
        case .text, .unknown: kind = "text"
        }
        var row: [String: Any] = [
          "id": property.id, "kind": kind, "label": plainLabel(property.labelHtml),
          "labelHTML": property.labelHtml == "ui_browse_properties_scheme_color" ? "" : property.labelHtml,
          "labelImages": PropertyImageCache.addresses(in: property.labelHtml),
          "value": propertyValue(property.value),
          "defaultValue": propertyValue(property.defaultValue),
          "enabled": property.enabled, "dirty": property.dirty,
          "min": property.slider?.min ?? 0, "max": property.slider?.max ?? 1,
          "step": property.slider?.step ?? 0.01,
          "options": property.comboOptions.map {
            ["label": engineTokenLabel($0.label) ?? $0.label, "value": propertyValue($0.value)]
          },
        ]
        guard property.kind == .file || property.kind == .directory else { return row }
        let asset = assets[property.id]
        // The page is shown the file's own name; the staged path it reads is never displayed.
        row["fileName"] = asset?.name as Any? ?? null
        row["fileTypes"] = assetFilter(property.fileFilter).allowedExtensions.sorted()
        row["error"] = errors[property.id] as Any? ?? null
        // Where the file actually lives now, and whether it is still there.
        // `assetSourcePath` is the user's original pick, shown so an external
        // reference can be recognised; it is not the path the renderer reads.
        row["assetManaged"] = property.assetManaged
        row["assetMissing"] = property.assetMissing
        row["assetSourcePath"] = property.assetSourcePath as Any? ?? null
        guard property.kind == .directory else { return row }
        row["directoryMode"] = property.directoryMode == .fetchAll ? "fetchAll" : "onDemand"
        let matches = asset?.matches
        row["fileCount"] = matches as Any? ?? null
        row["fileLimit"] = UserAssetStore.defaultDirectoryFileLimit
        row["truncated"] = asset?.truncated ?? false
        return row
      },
    ]
    payload.merge(delivered) { current, _ in current }
    return payload
  }

  /// An absent `fileFilter` means the author declared no file-type option, which the
  /// protocol defines as both kinds it knows, not as any file at all.
  static func assetFilter(_ value: BridgeFileFilter?) -> UserAssetFilter {
    switch value {
    case .image: .image
    case .video: .video
    case nil: .any
    }
  }

  static func propertyValue(_ value: BridgePropertyValue) -> Any {
    switch value {
    case .bool(let value): value
    case .number(let value): value
    case .string(let value): value
    case .colorRgb(let red, let green, let blue):
      String(
        format: "#%02x%02x%02x", Int(max(0, min(1, red)) * 255), Int(max(0, min(1, green)) * 255),
        Int(max(0, min(1, blue)) * 255))
    case .empty: NSNull()
    }
  }

  /// Plain names are retained for accessibility and native file pickers. The panel
  /// separately receives the untrusted markup and reconstructs allowed presentation.
  /// Empty decoration never falls back to the editor's markup-slug property id.
  static func plainLabel(_ html: String) -> String {
    // The editor writes this token in place of the scheme colour it adds to every scene.
    if html == "ui_browse_properties_scheme_color" { return String(localized: "Scheme color") }
    if let words = engineTokenLabel(html) { return words }
    let spaced = html.replacingOccurrences(
      of: "<(br|hr|/p|/div|/li|/tr|/h[1-6])\\b[^>]*>", with: " ",
      options: [.regularExpression, .caseInsensitive])
    return
      spaced
      .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
      .replacingOccurrences(of: "&nbsp;?", with: " ", options: .regularExpression)
      .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
      .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
      .replacingOccurrences(of: "&apos;", with: "'")
      .replacingOccurrences(of: "&amp;", with: "&")
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// `mwe-ui://<host>/<id>`, the panel-local address of a library wallpaper's preview file
  /// (`preview` for the file itself, `library-thumbnail` for its cached still). A still carries
  /// the stamp of the file (`LibraryPreviewFetcher.coverStamp`), so a preview that was replaced is
  /// not shown from the page's old image and one that was not keeps its address.
  static func libraryAddress(host: String, id: String, stamp: UInt64? = nil) -> String? {
    var components = URLComponents()
    components.scheme = "mwe-ui"
    components.host = host
    components.path = "/" + id
    if let stamp { components.queryItems = [URLQueryItem(name: "v", value: String(stamp))] }
    return components.url?.absoluteString
  }

  /// Whether the preview file can hold an animation, judged by its extension alone so that
  /// building a snapshot never touches the disk. A `.png` that is an APNG shows as a still.
  static func previewAnimates(_ file: URL) -> Bool {
    ["gif", "webp", "apng"].contains(file.pathExtension.lowercased())
  }

  /// Leading words of a built-in token that name the editor screen it came from, not the thing.
  private static let engineTokenAreaWords: Set<String> = [
    "editor", "browse", "settings", "workshop", "properties", "user", "scene", "options", "tags",
    "type", "effect", "preset", "layer", "importer", "gizmo", "context", "menu", "modal", "welcome",
  ]
  /// Trailing words that only say the token was a heading or caption.
  private static let engineTokenGenericWords: Set<String> = ["title", "label", "text"]
  private static let engineTokenMaxLength = 96

  /// The words for one of Wallpaper Engine's own `ui_…` label tokens, which a project that
  /// carries no text for them leaves as the label or combo choice. Nil for anything else:
  /// author prose, markup, or a token too long to be the editor's. Presentation only; the
  /// stored label and the choice's value are never rewritten. The words are English; the
  /// panel translates them when the same phrase is a catalog entry.
  static func engineTokenLabel(_ text: String) -> String? {
    let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard token.utf8.count <= engineTokenMaxLength, token.hasPrefix("ui_") else { return nil }
    let body = token.dropFirst(3)
    guard !body.isEmpty,
      body.unicodeScalars.allSatisfy({
        $0.isASCII && ($0 == "_" || $0.properties.isAlphabetic || ("0"..."9").contains($0))
      })
    else { return nil }
    var words = body.split(separator: "_").map(String.init)
    while words.count > 1, engineTokenAreaWords.contains(words[0].lowercased()) {
      words.removeFirst()
    }
    while words.count > 1, let last = words.last, engineTokenGenericWords.contains(last.lowercased()) {
      words.removeLast()
    }
    guard !words.isEmpty else { return nil }
    let joined = words.joined(separator: " ")
    return joined.prefix(1).uppercased() + joined.dropFirst()
  }

  static func workshopItem(_ value: WorkshopItem) -> [String: Any] {
    [
      "id": value.id, "title": value.title, "creator": value.creator, "summary": value.summary,
      "preview": value.previewURL?.absoluteString as Any? ?? NSNull(),
      "thumbnail": thumbnailAddress(for: value) as Any? ?? NSNull(),
      "animated": panelAddress(host: "animated", for: value) as Any? ?? NSNull(), "tags": value.tags,
      // Steam lists staff-approved wallpapers under the `Approved` tag; the tile marks them.
      "approved": value.tags.contains { $0.caseInsensitiveCompare("Approved") == .orderedSame },
      "size": value.size, "subscriptions": value.subscriptions, "kind": value.kind.rawValue,
      "creatorID": value.creatorID as Any? ?? NSNull(),
      "collection": value.collectionSize != nil, "collectionSize": value.collectionSize ?? 0,
    ]
  }

  /// The panel-local address of the item's cached still thumbnail; nil when Steam gave no preview.
  /// Title of a job or request that carries no Workshop item: the shared assets or a sign-in.
  static func itemlessTitle(_ id: String) -> String {
    id == WorkshopStore.signInRequestID
      ? String(localized: "Steam sign-in") : String(localized: "Scene assets")
  }

  static func thumbnailAddress(for value: WorkshopItem) -> String? {
    panelAddress(host: "thumbnail", for: value)
  }

  /// `mwe-ui://<host>/<id>`, the panel-local address `WebPanelAssets` serves for the item's
  /// preview (`thumbnail` for the still, `animated` for the relayed animation).
  static func panelAddress(host: String, for value: WorkshopItem) -> String? {
    guard value.previewURL?.scheme == "https" else { return nil }
    var components = URLComponents()
    components.scheme = "mwe-ui"
    components.host = host
    components.path = "/" + value.id
    return components.url?.absoluteString
  }
}
