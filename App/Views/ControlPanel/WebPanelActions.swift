import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
extension WebPanelController {
  func perform(_ action: String, body: [String: Any]) async throws {
    let request = WebPanelRequest(body)
    // Browsing and cancellation stay usable while a native operation awaits I/O. pixiv
    // browsing and downloads never touch the renderer, so they are always available.
    if try performPixiv(action, request: request) { return }
    if try await performLibraryOrganization(action, request: request) { return }
    if try await performDisplayLayouts(action, request: request) { return }
    if try performWallpaperAutomation(action, request: request) { return }
    if try await performBackup(action, request: request) { return }
    if try await performCompatibility(action, request: request) { return }
    if try await performLetterbox(action, request: request) { return }
    if try await performImagePlacement(action, request: request) { return }
    if try await performTelemetry(action, request: request) { return }
    if try await performSharing(action, request: request) { return }
    if try await performDisplayPosition(action, request: request) { return }
    switch action {
    case "ready":
      deliveredLibraryRevision = nil
      recoveryBudget.ready(at: ProcessInfo.processInfo.systemUptime)
      isReady = true
      Task { await workshop.steamCMDSetup.refresh() }
      return
    case "retryHostWallpaper":
      let id = try wallpaperID(request)
      guard let displayID = UInt32(try request.string("displayID")),
            store.hostWallpaperStates.values.contains(where: {
              $0.kind == .web && $0.wallpaperID == id && $0.displayID == displayID && $0.phase == .failed && $0.canRetry
            }) else { throw WebPanelRequest.invalid }
      store.retryHostWallpaper?(id, displayID)
      return
    case "releaseHeld":
      let id = try wallpaperID(request)
      // Only a wallpaper the app is holding back can be released; anything else is a stale tile.
      guard store.heldWallpaperIDs.contains(id) else { throw WebPanelRequest.invalid }
      try await store.commands.run(subject: id) {
        try await store.releaseHeldWallpaperAsync(id: id)
      }
      return
    case "themeSetting":
      try theme.set(try request.string("key"), value: try request.string("value"))
      return
    case "resetTheme":
      theme.reset()
      return
    case "languageSetting":
      try appLanguage.set(try request.string("value"))
      // The page switches from the snapshot it gets back; the user script is refreshed so a
      // later reload or WebContent recovery starts in the same language.
      installUserScript()
      // A wallpaper's own label tables follow the language too. The change has already
      // happened, so a failure here is logged and never fails it.
      do {
        try await store.setLabelLanguageAsync(appLanguage.effective)
      } catch {
        AppLog.warn("Property labels could not follow the new language: \(error.localizedDescription)")
      }
      return
    case "dismissError":
      actionError = nil
      imports.dismissFailure()
      dismissedErrorRevision = store.latestBridgeErrorRevision
      dismissedLibraryError = libraryFailureMessage
      dismissedDownloadError = workshop.downloader.errorMessage ?? workshop.downloadPersistenceError ?? pixiv.downloads.persistenceError
      return
    case "navigate":
      switch try request.string("page") {
      case "installed": navigation.selection = .wallpaper
      case "discover":
        navigation.selection = .workshop
        if !workshop.hasLoaded && !workshop.isLoading { workshop.search() }
      case "pixiv":
        navigation.selection = .pixiv
        if !pixiv.hasLoaded && !pixiv.isLoading { pixiv.apply(pixiv.query) }
      case "settings": navigation.selection = .settings
      default: throw WebPanelRequest.invalid
      }
      return
    case "workshopSearch":
      // The sidebar narrows by tags alone, so `kind` is optional and defaults to every type.
      let excludedTags = body["excludedTags"] as? [String] ?? []
      guard let kind = WorkshopKind(rawValue: body["kind"] as? String ?? WorkshopKind.all.rawValue),
        let sort = WorkshopSort(rawValue: try request.string("sort")),
        let tags = body["tags"] as? [String], tags.count <= 32, tags.allSatisfy({ $0.count <= 128 }),
        excludedTags.count <= 64, excludedTags.allSatisfy({ $0.count <= 128 })
      else { throw WebPanelRequest.invalid }
      workshop.searchText = try request.string("text")
      workshop.kind = kind
      workshop.sort = sort
      workshop.tags = tags
      workshop.excludedTags = excludedTags
      workshop.search()
      return
    // Where Discover looks. An author or a collection is opened from a tile, so Back returns.
    case "workshopSource":
      switch try request.string("source") {
      case "browse": workshop.open(.browse)
      case "collections": workshop.open(.collections)
      case "subscriptions": workshop.open(.subscriptions)
      default: throw WebPanelRequest.invalid
      }
      return
    case "workshopCreator":
      let id = try request.string("id")
      let name = try request.string("name")
      guard SteamWebSession.isSteamID(id), name.count <= 256 else { throw WebPanelRequest.invalid }
      workshop.open(.creator(id: id, name: name))
      return
    case "workshopCollection":
      let id = try request.string("id")
      let title = try request.string("title")
      guard !id.isEmpty, id.count <= 20, UInt64(id) != nil, title.count <= 512 else { throw WebPanelRequest.invalid }
      workshop.open(.collection(id: id, title: title))
      return
    case "workshopBack":
      workshop.back()
      return
    // Steam's own page in a window of its own; the panel learns the outcome from its snapshot.
    case "steamWebSignIn":
      if workshop.isSigningInToSteamWeb {
        WebSignInWindowController.bringToFront(.steam)
      } else if workshop.steamWebSession == nil {
        let obtain = signInToSteamWeb ?? { await WebSignInWindowController.obtainCookie(for: .steam) }
        Task { @MainActor [weak self] in
          guard let self else { return }
          do {
            try await self.workshop.signInToSteamWeb(obtainCookie: obtain)
          } catch {
            self.actionError = error.localizedDescription
          }
          self.scheduleUpdate()
        }
      }
      return
    case "steamWebSignOut":
      workshop.signOutOfSteamWeb()
      return
    case "workshopPage":
      workshop.loadPage(
        Int(try request.number("page", range: 1...Double(WorkshopStore.maxPages))))
      return
    case "workshopRetry":
      workshop.retrySearch()
      return
    case "filters":
      guard let page = body["page"] as? String, let key = Self.filtersCollapsedKeys[page],
        let collapsed = body["collapsed"] as? Bool
      else { throw WebPanelRequest.invalid }
      filtersCollapsed[page] = collapsed
      defaults.set(collapsed, forKey: key)
      return
    case "welcomeSeen":
      // Reading, skipping or simply starting to use the app all count; the welcome is
      // offered once and afterwards only on request from Settings.
      welcomeSeen = true
      defaults.set(true, forKey: Self.welcomeSeenKey)
      // The guide's Preferences page carries the performance data switch; someone who left
      // before reaching it is asked once later instead.
      if body["preferencesShown"] as? Bool == true { store.supportPrompt?.recordTelemetryAsked() }
      return
    case "dragSelectLearned":
      dragSelectLearned = true
      defaults.set(true, forKey: Self.dragSelectLearnedKey)
      return
    case "supportPromptShown":
      store.supportPrompt?.markPresented(try promptKind(request))
      return
    case "supportPromptChoice":
      let prompt = try promptKind(request)
      let url: URL
      switch (prompt, try request.string("choice")) {
      case (_, "dismiss"):
        store.supportPrompt?.markPresented(prompt)
        return
      case (.telemetry, "enableTelemetry"):
        store.telemetry?.setEnabled(true)
        store.supportPrompt?.markPresented(.telemetry)
        return
      case (.support, "star"), (.star, "star"): url = AppUpdateConfiguration.repositoryURL
      case (.support, "supporter"):
        let path = language.hasPrefix("zh") ? "zh/pricing/" : "pricing/"
        url = URL(string: "https://www.wallpapermachine.app/\(path)")!
      default: throw WebPanelRequest.invalid
      }
      guard openSupportURL(url) else {
        throw WallpaperActionError(message: String(localized: "The link could not be opened. Please try again."))
      }
      if url == AppUpdateConfiguration.repositoryURL { store.supportPrompt?.recordStarChosen() }
      store.supportPrompt?.markPresented(prompt)
      return
    case "workshopSelect":
      guard let id = body["id"] as? String, let item = workshop.workshopItem(id: id) else {
        throw WebPanelRequest.invalid
      }
      workshop.selectedItem = item
      return
    case "importCancel":
      imports.cancel()
      return
    case "downloadCancel":
      workshop.cancelDownload(id: try request.string("id"))
      return
    case "downloadPause":
      workshop.downloader.pause(try download(request))
      return
    case "downloadInput":
      let job = try download(request)
      let secret = try request.string("value")
      guard job.worker.prompt != nil, !secret.isEmpty,
        !secret.contains(where: { $0.isNewline || $0 == "\0" })
      else { throw WebPanelRequest.invalid }
      job.worker.submitSecret(secret)
      return
    case "setupCancel":
      workshop.steamCMDSetup.cancel()
      return
    case "checkForUpdates":
      _ = await updater.checkForUpdates()
      return
    case "downloadUpdate":
      _ = await updater.downloadUpdate()
      return
    case "cancelUpdate":
      updater.cancel()
      return
    case "openReleases":
      updater.openReleases()
      return
    case "revealDownloadedUpdate":
      updater.revealDownloadedUpdate()
      return
    // Automatic wallpaper choices can also change playlists. Serialize manual edits with
    // those choices so an in-flight activation cannot overwrite a newer setting.
    case "playlistSetting":
      try await editPlaylist(request) { request, _ in try playlistSetting(request) }
      return
    // Recorded in Settings → General: the page sends the key's position and the modifiers held.
    case "hotkeySet":
      guard let action = HotKeyAction(rawValue: try request.string("id")) else { throw WebPanelRequest.invalid }
      let hotKey = try GlobalHotKeys.hotKey(
        code: try request.string("code"), command: try request.boolean("command"),
        option: try request.boolean("option"), control: try request.boolean("control"),
        shift: try request.boolean("shift"))
      try hotKeys.set(hotKey, for: action)
      return
    case "hotkeyClear":
      guard let action = HotKeyAction(rawValue: try request.string("id")) else { throw WebPanelRequest.invalid }
      try hotKeys.set(nil, for: action)
      return
    case "workshopCheckUpdates":
      workshop.updates.check(
        installed: store.librarySnapshot.wallpapers.map(\.id), library: ClientPaths.libraryURL)
      return
    case "playlistAdd":
      try await editPlaylist(request) { request, display in
        playlists.add(try wallpaperIDs(request), to: display)
      }
      return
    case "playlistRemove":
      try await editPlaylist(request) { request, display in
        playlists.remove(try request.string("id"), from: display)
      }
      return
    case "playlistReorder":
      guard let ids = request.body["ids"] as? [String], ids.count <= 10_000,
            let expected = request.body["expectedIDs"] as? [String], expected.count <= 10_000
      else { throw WebPanelRequest.invalid }
      try await editPlaylist(request) { _, display in
        try playlists.reorder(ids, on: display, expected: expected)
      }
      return
    case "playlistClearFailures":
      playlists.clearFailures(on: try playlistDisplay(request))
      return
    case "historyClear":
      store.history.clear(on: try playlistDisplay(request))
      return
    case "previewWallpaper":
      let id = try wallpaperID(request)
      guard let preview = store.openPreview,
            store.librarySnapshot.wallpapers.contains(where: { $0.id == id && $0.supported })
      else { throw WebPanelRequest.invalid }
      let properties: [String: String]
      if let value = request.body["properties"] {
        guard let values = value as? [String: String], values.count <= 1_000,
              values.values.reduce(0, { $0 + $1.utf8.count }) <= 1024 * 1024 else { throw WebPanelRequest.invalid }
        properties = values
      } else { properties = [:] }
      let selection = WallpaperPreviewSession.Selection(wallpaperID: id, displayID: navigation.targetDisplayID, textOverrides: properties)
      try await store.commands.run(slot: "preview", subject: id) {
        guard store.librarySnapshot.wallpapers.contains(where: { $0.id == id && $0.supported })
        else { throw WebPanelRequest.invalid }
        preview(selection)
      }
      return
    // A slider or colour being dragged. Not a command: it changes no state a later command depends
    // on, and queued behind a running one it would reach the previews long after the thumb moved
    // on. Only sliders and colours take part, and a value is held to the rules of an edit's.
    case "propertyPreview":
      let id = try wallpaperID(request)
      let propertyID = try request.string("propertyID")
      let options = try await store.wallpaperOptionsSnapshotAsync(wallpaperId: id)
      guard let descriptor = options.properties.first(where: { $0.id == propertyID && $0.enabled }),
        descriptor.kind == .slider || descriptor.kind == .color
      else { throw WebPanelRequest.invalid }
      let value = try propertyValue(body["value"], descriptor: descriptor)
      await store.previewPropertyAsync(wallpaperId: id, propertyId: propertyID, value: value)
      return
    case "playlistSkip":
      let display = try playlistDisplay(request)
      guard playlists.skipHandler?(display) == true else {
        throw WallpaperActionError(
          message: playlists.playlist(for: display).mode == .rotate
            ? String(localized: "This display’s playlist has no other wallpaper to change to.")
            : String(localized: "This display has no rotating playlist to move along."))
      }
      return
    case "playlistResume":
      playlists.resumeHandler?(try playlistDisplay(request))
      return
    default: break
    }
    actionError = nil
    scheduleUpdate()
    switch action {
    // Neither touches the renderer, so neither waits behind a command that does.
    case "favorite":
      let id = try wallpaperID(request)
      if !favoriteIDs.insert(id).inserted { favoriteIDs.remove(id) }
      defaults.set(
        try JSONEncoder().encode(favoriteIDs.sorted()), forKey: Self.favoriteKey)
    case "reveal":
      NSWorkspace.shared.activateFileViewerSelecting([
        ClientPaths.libraryURL.appendingPathComponent(try wallpaperID(request))
      ])
    // Only the latest selection and the latest switch per display matter: a newer click
    // replaces one still waiting, and nothing the user asked for fails for being early.
    case "select":
      let id = try wallpaperID(request)
      try await store.commands.run(slot: BridgeStore.selectionSlot, subject: id) {
        try await store.selectWallpaperAsync(id: id)
      }
    // Applying the wallpaper a display already shows does nothing. Only the inspector's
    // **Reapply wallpaper** restarts it, so a tile's double-click, Recently used and Previous
    // keep leaving a running wallpaper alone.
    case "activate", "reapplyWallpaper":
      let id = try wallpaperID(request)
      let restarts = action == "reapplyWallpaper"
      // The display is the one targeted when the user asked, not when the command runs.
      let displayID = navigation.targetDisplayID
      let slot = BridgeStore.activationSlot(displayId: displayID)
      try await store.commands.run(slot: slot, subject: id) {
        if restarts {
          try await store.reapplyWallpaperAsync(id: id, displayId: displayID)
        } else {
          try await store.activateWallpaperAsync(id: id, displayId: displayID, origin: .user)
        }
        // Get out of the way so the freshly applied wallpaper is visible, unless another
        // switch is already waiting to replace it.
        if hidesAfterActivating, pendingPrompt() == nil,
          !store.commands.hasWaiting(slot: slot) { NSApp.hide(nil) }
      }
    // One wallpaper on every enabled independent display. The transfer takes its own turn in
    // the queue, so it must not run inside `commands.run` here.
    case "activateAll":
      try await store.activateWallpaperEverywhereAsync(id: try wallpaperID(request))
      if hidesAfterActivating, pendingPrompt() == nil, !store.commands.isBusy { NSApp.hide(nil) }
    case "previousWallpaper":
      let displayID = try playlistDisplay(request)
      try await store.commands.run(slot: BridgeStore.activationSlot(displayId: displayID)) {
        try await store.activatePreviousWallpaperAsync(displayId: displayID)
      }
    // Queues itself in the display's slot, like a switch, so it must not run inside the
    // queued commands below: a command that waits for the queue it holds never returns.
    case "sceneRetry":
      try await store.retryStoppedSceneAsync(displayId: try sceneDisplay(request))
    // The confirmation is asked before queueing, so an open sheet holds up nothing else.
    case "delete":
      let id = try wallpaperID(request)
      let title = store.librarySnapshot.wallpapers.first { $0.id == id }?.title ?? id
      guard
        await confirm(
          String(localized: "Move \(title) to Trash?"),
          detail: String(
            localized:
              "It is removed from your library and stops playing. The original files you imported are not affected."
          ),
          button: String(localized: "Move to Trash"))
      else { return }
      try await store.commands.run {
        try await store.deleteWallpaperAsync(id: id)
        try await forgetLibraryMetadata([id])
      }
    case "deleteMany":
      let ids = try wallpaperIDs(request)
      let title =
        ids.count == 1
        ? String(
          localized:
            "Move \(store.librarySnapshot.wallpapers.first(where: { $0.id == ids[0] })?.title ?? ids[0]) to Trash?")
        : String(localized: "Move \(ids.count) wallpapers to Trash?")
      guard
        await confirm(
          title,
          detail: String(
            localized:
              "They are removed from your library and stop playing. The original files you imported are not affected."
          ),
          button: String(localized: "Move to Trash"))
      else { return }
      try await store.commands.run {
        let report = try await store.deleteWallpapersAsync(ids: ids)
        try await forgetLibraryMetadata(report.deleted)
        if !report.failures.isEmpty {
          let titles = Dictionary(
            store.librarySnapshot.wallpapers.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
          let details = report.failures.map { "\(titles[$0.id] ?? $0.id): \($0.error.localizedDescription)" }
          throw WallpaperActionError(
            message: String(
              localized:
                "Moved \(report.deleted.count) of \(ids.count) wallpapers to Trash. Couldn’t move \(details.joined(separator: "; "))"
            )
          )
        }
      }
    // Every subscribed wallpaper the library lacks. Steam is asked outside the queue, which
    // only the downloads, queued like a single one, wait in.
    case "workshopDownloadSubscribed":
      let installed = Set(store.librarySnapshot.wallpapers.map(\.id))
      let missing = try await workshop.missingSubscriptions(installed: installed)
        .filter { $0.kind != .application }
      guard !missing.isEmpty else {
        throw WallpaperActionError(
          message: String(localized: "Every wallpaper you subscribe to is already in your library."))
      }
      try await store.commands.run {
        for item in missing where workshop.downloader.download(for: item.id)?.isPending != true {
          workshop.requestDownload(item: item, rememberSession: remembersSession, bridge: store)
          try checkDownloadError()
        }
      }
    default:
      try await store.commands.run { try await performQueued(action, request: request, body: body) }
    }
  }

  /// Commands that change renderer or app state, run one at a time through `store.commands`.
  private func performQueued(_ action: String, request: WebPanelRequest, body: [String: Any])
    async throws
  {
    if try await performPresets(action, request: request) { return }
    switch action {
    case "target":
      let id = try request.string("id")
      guard
        store.settingsSnapshot.displays.contains(where: {
          $0.displayId == id && $0.enabled && $0.mode == .standalone
        })
      else { throw WebPanelRequest.invalid }
      navigation.targetDisplayID = id
    case "apply":
      try await store.applyWallpaperOptionsAsync(wallpaperId: try wallpaperID(request), userInitiated: true)
    case "revert":
      try await store.cancelWallpaperOptionsAsync(wallpaperId: try wallpaperID(request))
    case "refresh":
      try await store.refreshAllAsync()
      try await store.refreshLibraryAsync()
    case "playback":
      if store.appSnapshot.playbackState == .paused {
        try await store.playAllAsync()
      } else {
        try await store.pauseAllAsync()
      }
    case "import": try await beginImport(request)
    case "wallpaperSetting": try await wallpaperSetting(request)
    case "displayConfig": try await displayConfig(request)
    case "property":
      let id = try wallpaperID(request)
      let propertyID = try request.string("propertyID")
      let options = try await store.wallpaperOptionsSnapshotAsync(wallpaperId: id)
      guard let descriptor = options.properties.first(where: { $0.id == propertyID && $0.enabled })
      else { throw WebPanelRequest.invalid }
      let value = try propertyValue(body["value"], descriptor: descriptor)
      try await store.editPropertyAsync(wallpaperId: id, propertyId: propertyID, value: value)
    case "restoreProperty":
      try await store.restorePropertyDefaultAsync(
        wallpaperId: try wallpaperID(request), propertyId: try request.string("propertyID"))
    case "restoreAllProperties":
      try await store.restoreAllPropertyDefaultsAsync(wallpaperId: try wallpaperID(request))
    case "choosePropertyFile":
      let id = try wallpaperID(request)
      let propertyID = try request.string("propertyID")
      let options = try await store.wallpaperOptionsSnapshotAsync(wallpaperId: id)
      guard
        options.properties.contains(where: {
          $0.id == propertyID && $0.enabled && $0.kind == .texture
        })
      else { throw WebPanelRequest.invalid }
      let panel = NSOpenPanel()
      panel.title = String(localized: "Choose Image")
      panel.allowedContentTypes = [.image]
      if await choose(panel), let url = panel.url {
        try await store.editPropertyAsync(
          wallpaperId: id, propertyId: propertyID, value: .string(value: url.path))
      }
    case "choosePropertyPath", "clearPropertyPath":
      try await propertyPath(choosing: action == "choosePropertyPath", request: request)
    case "setting":
      let key = try request.string("key")
      switch key {
      case "launchAtLogin":
        try await store.setLaunchAtLoginAsync(enabled: try request.boolean("value"))
      case "batteryMode":
        try await store.setBatteryModeAsync(try Self.batteryMode(request.string("value")))
      case "displaySleepAction":
        guard let action = DisplaySleepAction(rawValue: try request.string("value")) else {
          throw WebPanelRequest.invalid
        }
        playback.displaySleepAction = action
      case "otherAudioAction":
        guard let action = OtherAudioAction(rawValue: try request.string("value")) else {
          throw WebPanelRequest.invalid
        }
        playback.otherAudioAction = action
      case "desktopCoveredAction":
        guard let action = DesktopCoveredAction(rawValue: try request.string("value")) else {
          throw WebPanelRequest.invalid
        }
        playback.desktopCoveredAction = action
      case "lowPowerModeAction", "thermalAction":
        guard let action = SystemConditionAction(rawValue: try request.string("value")) else {
          throw WebPanelRequest.invalid
        }
        if key == "lowPowerModeAction" {
          playback.lowPowerModeAction = action
        } else {
          playback.thermalAction = action
        }
      case "lowBatteryAction":
        guard let action = SystemConditionAction(rawValue: try request.string("value")) else {
          throw WebPanelRequest.invalid
        }
        playback.lowBatteryAction = action
      case "lowBatteryThreshold":
        let thresholds = PlaybackPreferences.lowBatteryThresholds
        let value = try request.number(
          "value", range: Double(thresholds.min() ?? 0)...Double(thresholds.max() ?? 0))
        guard let level = Int(exactly: value), thresholds.contains(level) else {
          throw WebPanelRequest.invalid
        }
        playback.lowBatteryThreshold = level
      case "verboseLogging":
        try await store.setVerboseLoggingAsync(enabled: try request.boolean("value"))
      case "keepWindowsOnWallpaperClick":
        try DesktopClickRevealPreference.setEnabled(!(try request.boolean("value")))
      case "refreshDesktopPicture":
        playback.refreshesDesktopPicturePeriodically = try request.boolean("value")
      case "writeDesktopPicture":
        let writes = try request.boolean("value")
        if store.lockScreenWallpaper?.locksDesktopPictureChoice == true {
          throw WallpaperActionError(
            message: String(
              localized: "Turn off Animate lock screen before changing this: it sets the desktop picture itself."))
        }
        playback.writesDesktopPicture = writes
      case "playOnlyOnActiveDisplay":
        playback.playsOnlyOnActiveDisplay = try request.boolean("value")
      case "wallpapersMuted":
        playback.wallpapersMuted = try request.boolean("value")
      case "hideAfterActivating":
        defaults.set(try request.boolean("value"), forKey: Self.hideAfterActivatingKey)
      case "telemetry":
        let enabled = try request.boolean("value")
        // The switch is disabled without a service; a stale page must not stall the guide's
        // Continue, which stops at the first refused draft.
        guard let telemetry = store.telemetry else {
          AppLog.warn("telemetry: the switch was changed but sending is unavailable in this run")
          return
        }
        telemetry.setEnabled(enabled)
        // Chosen here, so the one-time question is answered.
        store.supportPrompt?.recordTelemetryAsked()
      case "inspectWebWallpapers":
        WebWallpaperInspection.setEnabled(try request.boolean("value"), defaults: defaults)
      case "livePropertyEdits":
        let enabled = try request.boolean("value")
        LivePropertyEditing.setEnabled(enabled, defaults: defaults)
        // Turning it off puts the saved look back on what the displays were shown; the edits
        // stay pending in the inspector.
        if !enabled { await store.stopShowingPropertyEditsOnDesktopAsync() }
      case "workshopUpdateChecks":
        workshop.updates.checksAutomatically = try request.boolean("value")
      case "concurrentDownloads":
        let range = WorkshopDownloadManager.concurrentDownloadRange
        let value = try request.number(
          "value", range: Double(range.lowerBound)...Double(range.upperBound))
        guard let count = Int(exactly: value) else { throw WebPanelRequest.invalid }
        workshop.setConcurrentDownloads(count)
      case "lockScreenEnabled":
        guard let lock = store.lockScreenWallpaper else {
          throw WallpaperActionError(
            message: String(localized: "Lock Screen integration is unavailable."))
        }
        let enabled = try request.boolean("value")
        if enabled, store.settingsSnapshot.displays.contains(where: { $0.enabled && $0.mode == .standalone
          && automations.configuration(for: $0.displayId).mode == .spaces }) {
          throw WallpaperActionError(message: String(localized: "Choose another automatic wallpaper mode for your displays before enabling animated lock-screen wallpaper."))
        }
        lock.setEnabled(enabled)
      case "screenSaverEnabled":
        guard let lock = store.lockScreenWallpaper else {
          throw WallpaperActionError(
            message: String(localized: "Screen saver integration is unavailable."))
        }
        lock.setScreenSaverEnabled(try request.boolean("value"))
      case "videoBackend":
        let mode = try request.string("value")
        // Refuse an unknown mode instead of falling back: silently substituting
        // Compatibility would leave the page reporting a choice never applied.
        guard Self.videoBackendModes.contains(mode) else { throw WebPanelRequest.invalid }
        try await store.setVideoBackendAsync(mode)
      case "renderScale":
        try await store.setRenderScaleAsync(
          Float(try request.clampedNumber("value", to: Self.renderScaleRange)))
      case "contentPacing":
        try await store.setContentPacingEnabledAsync(try request.boolean("value"))
      case "sharedVideoDecode":
        try await store.setSharedVideoDecodeEnabledAsync(try request.boolean("value"))
      case "sceneOptimization":
        try await store.setSceneOptimizationEnabledAsync(try request.boolean("value"))
      case "sceneOnDemand":
        try await store.setSceneOnDemandEnabledAsync(try request.boolean("value"))
      case "sceneVideoPlaneSampling":
        try await store.setSceneVideoPlaneSamplingEnabledAsync(try request.boolean("value"))
      case "sceneRenderer":
        let mode = try request.string("value")
        // Same refusal as videoBackend: substituting Compatibility for an
        // unrecognised name would leave the page showing a choice that was
        // never applied. The two names match the Rust side exactly.
        guard Self.sceneRendererModes.contains(mode) else { throw WebPanelRequest.invalid }
        try await store.setSceneRendererAsync(mode)
      case "batteryRenderScale", "batteryTargetFps":
        try await setBatteryQualityProfile(key: key, request: request)
      case "frameRateCap":
        try await store.setFrameRateCapAsync(try Self.frameRateCap(request))
      case "qualityPreset":
        try await applyQualityPreset(try request.string("value"))
      default: throw WebPanelRequest.invalid
      }
      if Self.renderingSettings.contains(key) { energyUsage.settingChanged() }
    case "appRuleAdd":
      try await addAppRule()
    case "appRuleUpdate":
      try await updateAppRule(request)
    case "appRuleRemove":
      guard let id = UUID(uuidString: try request.string("id")) else { throw WebPanelRequest.invalid }
      playback.removeRule(id: id)
    case "lockScreenRetry": store.lockScreenWallpaper?.retry(lockScreen: true)
    case "screenSaverRetry": store.lockScreenWallpaper?.retry(lockScreen: false)
    case "openLoginItemsSettings": openLoginItemsSettings()
    case "openFocusSettings":
      // Focus filters are added to a Focus there; the app cannot add its own.
      NSWorkspace.shared.open(Self.focusSettingsURL)
    case "displaySetting": try await displaySetting(request)
    case "eject":
      try await store.removeWallpaperFromDisplayAsync(
        displayId: try request.string("displayID"), wallpaperId: try wallpaperID(request))
    case "refreshDisplays": try await store.refreshDisplaysAsync()
    case "locateAssets":
      let panel = NSOpenPanel()
      panel.title = String(localized: "Locate Scene Assets")
      panel.canChooseDirectories = true
      panel.canChooseFiles = false
      if await choose(panel), let url = panel.url {
        try ClientPaths.configureAssetsFolder(at: url)
        workshop.refreshSceneAssetsReadiness()
        // Located assets satisfy the need, so the waiting intent is finished, not downloaded.
        workshop.removeDownloadRequest(id: WorkshopStore.sceneAssetsRequestID)
      }
    case "showLibrary": NSWorkspace.shared.open(ClientPaths.libraryURL)
    case "showLogs": NSWorkspace.shared.open(try store.logFolderURL())
    case "clearCache":
      if await confirm(
        String(localized: "Clear shader cache?"),
        detail: String(localized: "Shaders are rebuilt the next time wallpapers need them."),
        button: String(localized: "Clear Cache"))
      {
        try await store.clearShaderCacheAsync()
      }
    case "clearLogs":
      if await confirm(
        String(localized: "Clear logs?"),
        detail: String(localized: "Only diagnostic logs are removed. Wallpapers and settings are not affected."),
        button: String(localized: "Clear Logs"))
      {
        try store.clearLogsAsync()
      }
    case "exportDiagnostics":
      let panel = NSSavePanel()
      panel.title = String(localized: "Export Diagnostics")
      panel.message = String(localized: "Attach this file to your bug report.")
      panel.nameFieldStringValue = DiagnosticsBundle.suggestedFileName(at: Date())
      panel.allowedContentTypes = [.zip]
      panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
      if await choose(panel), let destination = panel.url {
        try await exportDiagnostics(to: destination)
        NSWorkspace.shared.activateFileViewerSelecting([destination])
      }
    case "revealUserAssets":
      UserAssetStorage.revealManagedDirectory()
    case "purgeUnreferencedUserAssets":
      // Named for what it does: the manifest's files are user-imported
      // originals that nothing can regenerate, so the confirmation says what
      // is kept, not only what goes.
      if await confirm(
        String(localized: "Clear unused caches?"),
        detail: String(
          localized: "Only caches that can be rebuilt are removed. Files you chose in wallpaper settings are kept."),
        button: String(localized: "Clear Caches"))
      {
        let released = try await UserAssetStorage.purgeUnreferencedDerivedCaches()
        // A negative figure would be a bug in the accounting, not a real
        // amount, so it is reported as nothing released rather than wrapped.
        userAssetsReleasedBytes = UInt64(max(0, released))
      }
    case "setupInstall":
      let exists = FileManager.default.fileExists(atPath: ClientPaths.managedSteamCMDURL.path)
      if workshop.steamCMDSetup.retainedCandidateURL != nil {
        workshop.steamCMDSetup.retryInstallation()
      } else {
        let approved =
          exists
          ? await confirm(
            String(localized: "Reinstall SteamCMD?"),
            detail: String(
              localized:
                "The new copy replaces the current one only after it passes validation. Wallpapers and your saved sign-in are kept."
            ),
            button: String(localized: "Reinstall")) : true
        if approved { workshop.steamCMDSetup.install(replacingExisting: exists) }
      }
    case "setupLocate":
      let panel = NSOpenPanel()
      panel.title = String(localized: "Locate SteamCMD")
      panel.canChooseDirectories = true
      panel.canChooseFiles = true
      if await choose(panel), let url = panel.url { workshop.steamCMDSetup.selectExisting(at: url) }
    case "setupApprove":
      let candidate = try await workshop.steamCMDSetup.prepareApproval()
      if await confirm(
        String(localized: "Allow this SteamCMD installation?"),
        detail: String(
          localized:
            "macOS has not approved this software, and running it may put your data at risk. Only files matching this fingerprint are allowed, and the quarantine flag is removed from this copy only. Gatekeeper and signature checks stay on for everything else.\n\nPath: \(candidate.rootURL.path)\nSHA-256: \(candidate.fingerprint)"
        ),
        button: String(localized: "Allow This Copy and Continue"))
      {
        workshop.steamCMDSetup.approveRetainedCandidate(candidate)
      }
    case "setupRevealCandidate":
      if let url = workshop.steamCMDSetup.retainedCandidateURL {
        NSWorkspace.shared.activateFileViewerSelecting([url])
      }
    case "setupDiscardCandidate":
      if await confirm(
        String(localized: "Discard downloaded SteamCMD?"),
        detail: String(
          localized: "Only this downloaded copy is removed. The installed SteamCMD and your saved sign-in are kept."),
        button: String(localized: "Discard Download"))
      {
        workshop.steamCMDSetup.discardRetainedCandidate()
      }
    case "requestDownload":
      let item: WorkshopItem?
      if let id = body["id"] as? String, id != WorkshopStore.sceneAssetsRequestID {
        guard let found = workshop.workshopItem(id: id) else { throw WebPanelRequest.invalid }
        // A collection is a list on Steam, not a wallpaper: it is opened, and its wallpapers
        // downloaded one by one.
        guard found.collectionSize == nil else {
          throw WallpaperActionError(
            message: String(localized: "A collection can’t be downloaded as one. Open it to download its wallpapers."))
        }
        item = found
      } else {
        item = nil
      }
      // **Download and apply** names no display: it is the one the panel targets when the
      // wallpaper is asked for, and it has to be one that can show a wallpaper of its own.
      var displayID: String?
      if try body["apply"] == nil ? false : request.boolean("apply") {
        guard item != nil else { throw WebPanelRequest.invalid }
        try store.validateActivationTarget(navigation.targetDisplayID)
        displayID = navigation.targetDisplayID
      }
      workshop.requestDownload(
        item: item, rememberSession: remembersSession, bridge: store, applyTo: displayID)
      try checkDownloadError()
    // An update downloads through the same queue and prerequisites as any Workshop item, and
    // replaces the installed copy once it has arrived whole.
    case "workshopUpdate":
      guard let item = workshop.updates.available[try wallpaperID(request)] else {
        throw WebPanelRequest.invalid
      }
      workshop.requestDownload(item: item, rememberSession: remembersSession, bridge: store)
      try checkDownloadError()
    // Reinstalling downloads an installed wallpaper again, whether or not its author changed it,
    // and swaps it in once it has arrived whole: the same queue, prerequisites and replacement
    // as an update, so a failed download leaves the installed copy where it is.
    case "workshopReinstall":
      let id = try wallpaperID(request)
      if await confirm(
        String(localized: "Reinstall this wallpaper?"),
        detail: String(
          localized:
            "WallpaperMachine downloads it again from the Steam Workshop and swaps it in when the download is complete. Your settings for it are kept, and if the download fails the installed copy stays."
        ),
        button: String(localized: "Reinstall"))
      {
        try await workshop.requestReinstall(id: id, rememberSession: remembersSession, bridge: store)
        try checkDownloadError()
      }
    case "workshopUpdateAll":
      for item in workshop.updates.available.values.sorted(by: { $0.title < $1.title })
      where workshop.downloader.download(for: item.id)?.isPending != true {
        workshop.requestDownload(item: item, rememberSession: remembersSession, bridge: store)
        try checkDownloadError()
      }
    case "continueDownload":
      let account = try request.string("account")
      remembersSession = try request.boolean("rememberSession")
      guard
        workshop.continueDownload(
          id: try request.string("id"), account: account, rememberSession: remembersSession,
          includeResources: try request.boolean("includeResources"), bridge: store)
      else { throw WebPanelRequest.invalid }
      try checkDownloadError()
    case "steamSignIn":
      // The welcome guide and Settings verify an account ahead of any download. The password is
      // never part of this message: Steam asks for it through the job's own prompt.
      let account = try request.string("account")
      remembersSession = try request.boolean("rememberSession")
      workshop.requestSignIn(account: account, rememberSession: remembersSession, bridge: store)
      try checkDownloadError()
    case "removeDownloadRequest":
      // Dismissal is idempotent: a request that just started is already gone from the queue.
      workshop.removeDownloadRequest(id: try request.string("id"))
    case "changeDownloadAccount":
      await workshop.changeDownloadAccount(id: try download(request).id)
    case "downloadResume":
      let id = try request.string("id")
      if !workshop.resumeDownloadRequest(id: id, bridge: store) {
        workshop.resumeDownload(try download(request), bridge: store)
      }
      try checkDownloadError()
    case "downloadRetry":
      let job = try download(request)
      guard !job.isPending else { throw WebPanelRequest.invalid }
      // A retry re-enters the same prerequisite ladder; shared assets need consent again.
      workshop.continueDownload(
        id: job.id, account: job.account, rememberSession: remembersSession,
        includeResources: false, bridge: store)
      try checkDownloadError()
    case "clearDownloads":
      workshop.clearDownloadActivity()
      pixiv.downloads.clearFinished()
    case "logOutSteam":
      let account = workshop.downloader.savedAccount ?? ""
      if await confirm(
        String(localized: "Log out of Steam?"),
        detail: String(
          localized:
            "The saved sign-in for \(account) will be removed from this Mac. Other Steam devices stay signed in, and the next download asks you to sign in again."
        ),
        button: String(localized: "Log Out"))
      {
        workshop.downloader.forgetSavedAccount()
        if let error = workshop.downloader.errorMessage {
          throw WallpaperActionError(message: error)
        }
      }
    case "openExternal":
      guard let url = URL(string: try request.string("url")), Self.allowedExternalURL(url) else {
        throw WebPanelRequest.invalid
      }
      NSWorkspace.shared.open(url)
    case "installUpdate":
      if await confirm(
        String(localized: "Restart and install this update?"),
        detail: String(
          localized: "The current app will quit and be replaced. Wallpapers and settings are kept."),
        button: String(localized: "Restart and Install"))
      {
        await updater.installUpdate()
      }
    default: throw WebPanelRequest.invalid
    }
  }

  func wallpaperID(_ request: WebPanelRequest) throws -> String {
    let id = try request.string("id")
    guard store.librarySnapshot.wallpapers.contains(where: { $0.id == id }) else {
      throw WallpaperActionError(
        message: String(localized: "This wallpaper is no longer installed. Refresh your library."))
    }
    return id
  }

  /// Distinct installed ids, in request order; any unknown id rejects the whole batch.
  func wallpaperIDs(_ request: WebPanelRequest) throws -> [String] {
    guard let raw = request.body["ids"] as? [String], !raw.isEmpty, raw.count <= 4096 else {
      throw WebPanelRequest.invalid
    }
    let installed = Set(store.librarySnapshot.wallpapers.map(\.id))
    var seen = Set<String>()
    let ids = raw.filter { seen.insert($0).inserted }
    guard ids.allSatisfy(installed.contains) else {
      throw WallpaperActionError(
        message: String(localized: "Some selected wallpapers are no longer installed. Refresh your library."))
    }
    return ids
  }

  func forgetFavorites(_ ids: [String]) throws {
    guard ids.contains(where: favoriteIDs.contains) else { return }
    favoriteIDs.subtract(ids)
    defaults.set(
      try JSONEncoder().encode(favoriteIDs.sorted()), forKey: Self.favoriteKey)
  }

  private func forgetLibraryMetadata(_ ids: [String]) async throws {
    var firstError: Error?
    do { try forgetFavorites(ids) } catch { firstError = error }
    playlists.forget(ids)
    do { try automations.forgetWallpapers(Set(ids)) } catch { firstError = firstError ?? error }
    store.history.forget(Set(ids))
    workshop.updates.forget(ids)
    do { try collections.forget(ids) } catch { firstError = firstError ?? error }
    do { try await presets.forget(wallpaperIDs: ids) } catch { firstError = firstError ?? error }
    do { try imagePlacement.forget(Set(ids)) } catch { firstError = firstError ?? error }
    if let firstError { throw firstError }
  }

  /// The display a playlist action names, or the target display when it names none. Only an
  /// enabled display that shows its own wallpaper has a playlist.
  func playlistDisplay(_ request: WebPanelRequest) throws -> String {
    let id = request.body["displayID"] == nil ? navigation.targetDisplayID : try request.string("displayID")
    guard
      store.settingsSnapshot.displays.contains(where: {
        $0.displayId == id && $0.enabled && $0.mode == .standalone
      })
    else { throw WebPanelRequest.invalid }
    return id
  }

  /// The panel's id for the display a scene report names. The page knows it by the physical
  /// id the report carries, so the id is looked up among the displays that can run a
  /// scene; one that is gone or disabled has nothing to retry. A display that mirrors another
  /// presents a scene of its own, so it is accepted, and the store reloads the display it mirrors.
  func sceneDisplay(_ request: WebPanelRequest) throws -> String {
    guard let physical = UInt32(exactly: try request.number("displayId", range: 0...Double(UInt32.max))),
      let display = store.settingsSnapshot.displays.first(where: {
        $0.enabled && ResolvedDisplayTitles.liveDisplayID($0.displayId, title: $0.title) == physical
      })
    else { throw WebPanelRequest.invalid }
    return display.displayId
  }

  func playlistSetting(_ request: WebPanelRequest) throws {
    let display = try playlistDisplay(request)
    switch try request.string("key") {
    case "mode":
      guard let mode = PlaylistMode(rawValue: try request.string("value")) else { throw WebPanelRequest.invalid }
      playlists.update(display) { $0.mode = mode }
    case "source":
      guard let source = PlaylistSource(rawValue: try request.string("value")) else { throw WebPanelRequest.invalid }
      if source == .collection {
        guard let id = playlists.playlist(for: display).collectionID,
          collections.collection(id: id) != nil
        else { throw LibraryOrganizationError.missingCollection }
      }
      playlists.update(display) { $0.source = source }
    case "collectionID":
      let id = try request.string("value")
      guard collections.collection(id: id) != nil else { throw LibraryOrganizationError.missingCollection }
      playlists.update(display) {
        $0.collectionID = id
        $0.source = .collection
      }
    case "order":
      guard let order = PlaylistOrder(rawValue: try request.string("value")) else { throw WebPanelRequest.invalid }
      playlists.update(display) { $0.order = order }
    case "interval":
      let range = DisplayPlaylist.intervalRange
      let minutes = try request.number("value", range: Double(range.lowerBound)...Double(range.upperBound))
      guard minutes == minutes.rounded() else { throw WebPanelRequest.invalid }
      // Choosing a time is choosing to change on a timer again.
      playlists.update(display) {
        $0.interval = Int(minutes)
        $0.trigger = .interval
      }
    case "trigger":
      guard let trigger = PlaylistTrigger(rawValue: try request.string("value")) else { throw WebPanelRequest.invalid }
      playlists.update(display) { $0.trigger = trigger }
    case "dayWallpaper", "nightWallpaper":
      // Empty clears the choice; anything else must be a wallpaper that can play.
      let value = try request.string("value")
      guard value.isEmpty || store.librarySnapshot.wallpapers.contains(where: { $0.id == value && $0.supported })
      else { throw WebPanelRequest.invalid }
      let id = value.isEmpty ? nil : value
      if request.body["key"] as? String == "dayWallpaper" {
        playlists.update(display) { $0.dayWallpaperID = id }
      } else {
        playlists.update(display) { $0.nightWallpaperID = id }
      }
    case "dayStart", "nightStart":
      let minute = Int(try request.number("value", range: 0...Double(DisplayPlaylist.minutesPerDay - 1)))
      if request.body["key"] as? String == "dayStart" {
        playlists.update(display) { $0.dayStart = minute }
      } else {
        playlists.update(display) { $0.nightStart = minute }
      }
    default: throw WebPanelRequest.invalid
    }
  }

  private func editPlaylist(_ request: WebPanelRequest,
                            _ change: (WebPanelRequest, String) throws -> Void) async throws {
    let display = try playlistDisplay(request)
    var body = request.body
    body["displayID"] = display
    let pinned = WebPanelRequest(body)
    // Each field edit is retained; different settings must not coalesce in the activation slot.
    try await store.commands.run {
      _ = try playlistDisplay(pinned)
      try change(pinned, display)
      automations.manualChoice?(display)
    }
  }

  func download(_ request: WebPanelRequest) throws -> WorkshopDownload {
    guard
      let job = workshop.downloader.downloads.first(where: {
        $0.id == (request.body["id"] as? String)
      })
    else { throw WebPanelRequest.invalid }
    return job
  }

  func checkDownloadError() throws {
    if let error = workshop.downloader.errorMessage ?? workshop.downloadPersistenceError {
      throw WallpaperActionError(message: error)
    }
  }

  func wallpaperSetting(_ request: WebPanelRequest) async throws {
    let id = try wallpaperID(request)
    switch try request.string("key") {
    case "volume":
      try await store.setVolumeAsync(
        wallpaperId: id, volume: Float(try request.number("value", range: 0...1)))
    case "muted":
      try await store.setMutedAsync(wallpaperId: id, muted: try request.boolean("value"))
    case "audioResponseEnabled":
      try await store.setAudioResponseEnabledAsync(
        wallpaperId: id, enabled: try request.boolean("value"))
    case "mediaIntegrationEnabled":
      try await store.setMediaIntegrationEnabledAsync(
        wallpaperId: id, enabled: try request.boolean("value"))
    default: throw WebPanelRequest.invalid
    }
  }

  /// Chooses or clears the path a `file` / `directory` property points at.
  ///
  /// A failure is recorded against the property rather than thrown: the window-wide
  /// banner cannot say which of several pickers failed, and a picker that closes and
  /// changes nothing tells the user least of all.
  func propertyPath(choosing: Bool, request: WebPanelRequest) async throws {
    let id = try wallpaperID(request)
    let propertyID = try request.string("propertyID")
    let options = try await store.wallpaperOptionsSnapshotAsync(wallpaperId: id)
    guard let descriptor = options.properties.first(where: { $0.id == propertyID && $0.enabled }),
      descriptor.kind == .file || descriptor.kind == .directory
    else { throw WebPanelRequest.invalid }
    propertyPathErrors[id]?[propertyID] = nil
    propertyAssets[id]?[propertyID] = nil
    guard choosing else {
      try await store.setPropertyPathAsync(wallpaperId: id, propertyId: propertyID, path: nil)
      return
    }
    let directory = descriptor.kind == .directory
    let label = Self.plainLabel(descriptor.labelHtml)
    let panel = NSOpenPanel()
    panel.title = directory ? String(localized: "Choose Folder") : String(localized: "Choose File")
    panel.message =
      directory
      ? String(localized: "Choose a folder for \(label).") : String(localized: "Choose a file for \(label).")
    panel.canChooseDirectories = directory
    panel.canChooseFiles = !directory
    panel.canCreateDirectories = false
    if !directory {
      let types = Self.assetFilter(descriptor.fileFilter).allowedExtensions.sorted()
        .compactMap { UTType(filenameExtension: $0) }
      if !types.isEmpty { panel.allowedContentTypes = types }
    }
    guard await choose(panel), let url = panel.url else { return }
    if let reason = Self.stagingObstacle(wallpaperID: id) {
      propertyPathErrors[id, default: [:]][propertyID] = reason
      return
    }
    let current = try await store.wallpaperOptionsSnapshotAsync(wallpaperId: id)
    guard current.properties.contains(where: {
      $0.id == propertyID && $0.enabled && $0.kind == descriptor.kind
    }) else { throw WebPanelRequest.invalid }
    // Only the extension is sandboxed, so this plain path stays readable across
    // relaunches; do not add security-scoped bookmarks.
    try await UserAssetSelectionAuthorization.perform(
      managed: ManagedUserAssetStore(), wallpaperID: id, selections: [propertyID: url.path]
    ) {
      try await store.setPropertyPathAsync(wallpaperId: id, propertyId: propertyID, path: url.path)
    }
  }

  /// Why this wallpaper cannot hold a staged copy of a user-chosen file.
  ///
  /// WebKit only grants a page read access below its own project folder, so the file has
  /// to be staged inside it. A folder the app cannot write to defeats the choice before
  /// the engine ever sees it, and the user is owed that reason at the moment of picking.
  static func stagingObstacle(wallpaperID: String) -> String? {
    let project = ClientPaths.libraryURL.appendingPathComponent(wallpaperID)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: project.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { return String(localized: "This wallpaper’s folder is missing, so the file cannot be prepared for it.") }
    guard FileManager.default.isWritableFile(atPath: project.path) else {
      return String(localized: "This wallpaper’s folder is read-only, so the file cannot be prepared for it.")
    }
    return nil
  }

  func displayConfig(_ request: WebPanelRequest) async throws {
    let id = try wallpaperID(request)
    let display = try request.string("displayID")
    switch try request.string("key") {
    case "enabled":
      try await store.setDisplayConfigEnabledAsync(
        wallpaperId: id, displayId: display, enabled: try request.boolean("value"))
    case "scalingMode":
      try await store.setScalingModeAsync(
        wallpaperId: id, displayId: display, mode: try request.scaling())
    case "scalingFactor":
      try await store.editScalingFactorAsync(
        wallpaperId: id, displayId: display,
        factor: try request.number(
          "value", range: Double.leastNonzeroMagnitude...Double.greatestFiniteMagnitude))
    case "fps":
      let options = try await store.wallpaperOptionsSnapshotAsync(wallpaperId: id)
      guard let row = options.displayConfigurations.first(where: { $0.displayId == display }) else {
        throw WebPanelRequest.invalid
      }
      try await store.setTargetFpsAsync(
        wallpaperId: id, displayId: display,
        fps: UInt32(try request.number("value", range: 1...Double(max(1, row.maxFps)))))
    default: throw WebPanelRequest.invalid
    }
  }

  func displaySetting(_ request: WebPanelRequest) async throws {
    let id = try request.string("displayID")
    let key = try request.string("key")
    guard let display = store.settingsSnapshot.displays.first(where: { $0.displayId == id }) else {
      throw WebPanelRequest.invalid
    }
    switch key {
    case "enabled":
      try await store.setDisplayEnabledAsync(displayId: id, enabled: try request.boolean("value"))
    case "mode":
      let mode = try request.string("value")
      guard ["standalone", "mirror"].contains(mode) else { throw WebPanelRequest.invalid }
      try await store.setDisplayModeAsync(
        displayId: id, mode: mode == "mirror" ? .mirror : .standalone)
    case "mirrorTarget":
      try await store.setMirrorTargetAsync(
        displayId: id, targetDisplayId: try request.string("value"))
    default:
      if display.mode == .mirror {
        switch key {
        case "scalingMode":
          try await store.setMirrorScalingModeAsync(displayId: id, mode: try request.scaling())
        case "scalingFactor":
          try await store.setMirrorScalingFactorAsync(
            displayId: id,
            factor: try request.number(
              "value", range: Double.leastNonzeroMagnitude...Double.greatestFiniteMagnitude))
        case "fps":
          try await store.setMirrorTargetFpsAsync(
            displayId: id,
            fps: UInt32(try request.number("value", range: 1...Double(max(1, display.maxFps)))))
        case "volume":
          try await store.setMirrorVolumeAsync(
            displayId: id, volume: Float(try request.number("value", range: 0...1)))
        case "muted":
          try await store.setMirrorMutedAsync(displayId: id, muted: try request.boolean("value"))
        default: throw WebPanelRequest.invalid
        }
      } else {
        guard
          let wallpaper = store.monitorInformationSnapshot.rows.first(where: { $0.displayId == id }
          )?.wallpaperId
        else {
          throw WallpaperActionError(
            message: String(localized: "Choose a wallpaper for this display first."))
        }
        var body = request.body
        body["id"] = wallpaper
        if key == "volume" || key == "muted" {
          try await wallpaperSetting(WebPanelRequest(body))
        } else {
          try await displayConfig(WebPanelRequest(body))
        }
        try await store.applyWallpaperOptionsAsync(wallpaperId: wallpaper)
      }
    }
  }

  func propertyValue(_ value: Any?, descriptor: BridgePropertyDescriptor) throws
    -> BridgePropertyValue
  {
    switch descriptor.kind {
    case .bool: return .bool(value: try WebPanelRequest(["value": value as Any]).boolean("value"))
    case .slider:
      return .number(
        value: try WebPanelRequest(["value": value as Any]).number(
          "value", range: (descriptor.slider?.min ?? 0)...(descriptor.slider?.max ?? 1)))
    // `file` and `directory` are excluded on purpose: their path travels through
    // setPropertyPath, not through the generic property editor.
    case .textInput, .texture:
      guard let value = value as? String, value.count <= 65_536 else {
        throw WebPanelRequest.invalid
      }
      return .string(value: value)
    case .color:
      guard let hex = value as? String, hex.count == 7, hex.first == "#",
        let rgb = UInt32(hex.dropFirst(), radix: 16)
      else { throw WebPanelRequest.invalid }
      return .colorRgb(
        red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255,
        blue: Double(rgb & 255) / 255)
    case .combo:
      guard let value,
        let option = descriptor.comboOptions.first(where: {
          NSDictionary(dictionary: ["v": Self.propertyValue($0.value)]).isEqual(to: ["v": value])
        })
      else { throw WebPanelRequest.invalid }
      return option.value
    default: throw WebPanelRequest.invalid
    }
  }

  func beginImport(_ request: WebPanelRequest) async throws {
    guard !imports.isBusy, !importPicker.isPresenting else {
      throw WallpaperActionError(message: String(localized: "An import is already running."))
    }
    let policy = WallpaperImportService.DuplicatePolicy(panelValue: request.body["duplicates"])
    guard let window = webView?.window else { return }
    // A project's own files stand for its folder (project.json, scene.json, scene.pkg).
    let types: [UTType] =
      [.folder, .json]
      + WallpaperImportService.videoExtensions.union(WallpaperImportService.webExtensions)
      .union(WallpaperImportService.imageExtensions).union(["pkg"]).sorted()
      .compactMap { UTType(filenameExtension: $0) }
    guard let urls = try await importPicker.choose(
      for: window, language: appLanguage.effective.tag, allowedContentTypes: types), !stopped
    else { return }
    try imports.start(urls, duplicates: policy)
  }

  func choose(_ panel: NSSavePanel) async -> Bool {
    guard let window = webView?.window else { return false }
    return await withCheckedContinuation { continuation in
      panel.beginSheetModal(for: window) { continuation.resume(returning: $0 == .OK) }
    }
  }

  /// Writes the diagnostics bundle off the main actor: reading and redacting
  /// up to 64 MB of logs must not stall the panel.
  func exportDiagnostics(to destination: URL) async throws {
    let settings = store.settingsSnapshot
    let throttle = Self.qualityThrottle(settings.qualityThrottle).joined(separator: ", ")
    var environment = DiagnosticEnvironment.current()
    environment.append("""
      settings: scene renderer \(settings.sceneRenderer), video backend \(settings.videoBackend), \
      render scale \(settings.renderScale) (preferred \(settings.preferredRenderScale)), battery mode \
      \(settings.batteryMode), frame-rate cap \(settings.frameRateCap.map(String.init) ?? "none"), on battery \
      \(settings.onBatteryPower), reduced quality for \(throttle.isEmpty ? "nothing" : throttle), effective \
      frame-rate cap \(settings.effectiveFrameRateCap.map(String.init) ?? "none"), verbose logging \
      \(settings.verboseLogging)
      """)
    for scene in settings.sceneRenderers {
      let mode = settings.sceneUpdateModes.first { $0.displayId == scene.displayId }?.mode
      environment.append(DiagnosticEnvironment.runningSceneLine(scene, mode: mode))
    }
    // Read once, here: the report is the only consumer, so nothing polls the window server.
    environment.append(contentsOf: DesktopWindowDiagnostics.current())
    environment.append(ProcessFootprint.reportLine(
      bytes: ProcessFootprint.current(), wallpaperWindows: WallpaperPresentationPolicy.wallpaperWindows().count))
    let bundle = DiagnosticsBundle(
      sources: DiagnosticsBundle.sources(logsRoot: try store.logFolderURL()),
      redactor: DiagnosticsRedactor(
        homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
        userNames: [NSUserName(), NSFullUserName()],
        secrets: [workshop.downloader.savedAccount].compactMap { $0 }))
    let date = Date()
    let report = try await Task.detached(priority: .userInitiated) {
      try bundle.export(to: destination, environment: environment, at: date)
    }.value
    AppLog.info("""
      diagnostics exported: \(report.included.count) files\
      \(report.missing.isEmpty ? "" : "; not included: \(report.missing.joined(separator: "; "))")
      """)
  }

  static let focusSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Focus-Settings.extension")!
  static let videoBackendModes = ["compatibility", "native_preferred"]
  /// The only two scene renderer names. Must stay identical to the Rust
  /// `set_scene_renderer` match arms: a name accepted here and rejected there
  /// would surface as a bridge error the user cannot act on.
  static let sceneRendererModes = ["compatibility", "native_metal_preferred"]
  static let renderScaleRange: ClosedRange<Double> = 0.25...1
  static let batteryTargetFpsRange: ClosedRange<Double> = 1...240
  /// Settings that change how much rendering work runs now, so the energy readout
  /// restarts its window and compares before with after. Battery quality counts only
  /// while it is in force, and so does what a Low Power Mode, a hot Mac or a low battery
  /// asks for, but restarting on them anyway costs a few seconds of readout. A condition
  /// choice reaches the renderer a moment after it is made, through the presentation
  /// policy; the restart only takes a baseline sample, and the figure compared is the
  /// window that follows, so that moment is a small part of it.
  static let renderingSettings: Set<String> = [
    "batteryMode", "batteryRenderScale", "batteryTargetFps", "frameRateCap", "qualityPreset",
    "renderScale", "videoBackend", "contentPacing", "sharedVideoDecode", "sceneOptimization",
    "sceneOnDemand", "sceneVideoPlaneSampling", "sceneRenderer", "lowPowerModeAction",
    "thermalAction", "lowBatteryAction",
  ]

  /// The engine owns the battery scale and frame rate as one value, so a single
  /// changed control is merged with the other as the engine currently reports it.
  func setBatteryQualityProfile(key: String, request: WebPanelRequest) async throws {
    let settings = store.settingsSnapshot
    var scale = settings.batteryRenderScale
    var fps = settings.batteryTargetFps
    switch key {
    case "batteryRenderScale":
      scale = Float(try request.clampedNumber("value", to: Self.renderScaleRange))
    case "batteryTargetFps":
      fps = UInt32(try request.clampedNumber("value", to: Self.batteryTargetFpsRange).rounded())
    default: throw WebPanelRequest.invalid
    }
    try await store.setBatteryQualityProfileAsync(renderScale: scale, targetFps: fps)
  }

  func applyQualityPreset(_ name: String) async throws {
    let scale: Float
    let cap: UInt32?
    switch name {
    case "low": (scale, cap) = (0.5, 30)
    case "medium": (scale, cap) = (0.75, 60)
    case "high": (scale, cap) = (1, nil)
    default: throw WebPanelRequest.invalid
    }
    try await store.setRenderScaleAsync(scale)
    try await store.setFrameRateCapAsync(cap)
  }

  static func batteryMode(_ value: String) throws -> BridgeBatteryMode {
    switch value {
    case "keepRunning": .keepRunning
    case "reducedQuality": .reducedQuality
    case "pause": .pause
    default: throw WebPanelRequest.invalid
    }
  }

  /// Null is no limit. A number is clamped to 1...240 and rounded.
  static func frameRateCap(_ request: WebPanelRequest) throws -> UInt32? {
    guard let value = request.body["value"] else { throw WebPanelRequest.invalid }
    if value is NSNull { return nil }
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
      number.doubleValue.isFinite
    else { throw WebPanelRequest.invalid }
    let clamped = min(max(number.doubleValue, 1), 240)
    return UInt32(clamped.rounded())
  }

  func addAppRule() async throws {
    guard let url = await chooseApplicationURL() else { return }
    guard let bundleID = Bundle(url: url)?.bundleIdentifier else {
      throw WallpaperActionError(
        message: String(localized: "This app has no bundle identifier, so it can’t be used in an app rule."))
    }
    var name = FileManager.default.displayName(atPath: url.path)
    if name.lowercased().hasSuffix(".app") {
      name = String(name.dropLast(4))
    }
    playback.addRule(bundleIdentifier: bundleID, name: name)
  }

  func updateAppRule(_ request: WebPanelRequest) async throws {
    guard let id = UUID(uuidString: try request.string("id")) else { throw WebPanelRequest.invalid }
    switch try request.string("key") {
    case "condition":
      guard let condition = AppRuleCondition(rawValue: try request.string("value")) else {
        throw WebPanelRequest.invalid
      }
      try playback.updateRule(id: id, condition: condition)
    case "action":
      guard let action = AppRuleAction(rawValue: try request.string("value")) else {
        throw WebPanelRequest.invalid
      }
      try playback.updateRule(id: id, action: action)
    default: throw WebPanelRequest.invalid
    }
  }

  func chooseApplicationURL() async -> URL? {
    if let chooseApplication { return await chooseApplication() }
    let panel = NSOpenPanel()
    panel.title = String(localized: "Choose App")
    panel.allowedContentTypes = [.application]
    panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.treatsFilePackagesAsDirectories = false
    guard await choose(panel) else { return nil }
    return panel.url
  }

  func confirm(_ title: String, detail: String, button: String) async -> Bool {
    guard let window = webView?.window else { return false }
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = detail
    alert.addButton(withTitle: button)
    alert.addButton(withTitle: String(localized: "Cancel"))
    return await withCheckedContinuation { continuation in
      alert.beginSheetModal(for: window) {
        continuation.resume(returning: $0 == .alertFirstButtonReturn)
      }
    }
  }

  /// Which one-time prompt a page message is about; pages from before there were three name none.
  func promptKind(_ request: WebPanelRequest) throws -> SupportPromptStore.Prompt {
    guard request.body["prompt"] != nil else { return .support }
    guard let prompt = SupportPromptStore.Prompt(rawValue: try request.string("prompt")) else {
      throw WebPanelRequest.invalid
    }
    return prompt
  }

  static func allowedExternalURL(_ url: URL) -> Bool {
    guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil else {
      return false
    }
    return [
      "steamcommunity.com", "store.steampowered.com", "help.steampowered.com", "github.com", "www.gnu.org",
      "support.apple.com", "space.bilibili.com", "www.bilibili.com", "www.pixiv.net",
    ].contains(url.host ?? "")
  }

  /// Keeps the page's last valid report of Installed's filters and library scroll offsets.
  /// A report that does not validate is dropped and the previous one stays.
  func storeViewState(_ body: [String: Any]) {
    guard let viewState = PanelViewState(validating: body) else {
      AppLog.debug("Panel view state ignored: the page sent a value outside its limits")
      return
    }
    navigation.viewState = viewState
  }
}

extension WallpaperImportService.DuplicatePolicy {
  /// The policy the import popover's choice names. Anything it does not recognize keeps what the
  /// library holds: a stale page must never be able to replace an installed wallpaper.
  init(panelValue: Any?) {
    switch panelValue as? String {
    case "keepBoth": self = .keepBoth
    case "replaceChanged": self = .replaceChanged
    default: self = .skip
    }
  }
}

struct WebPanelRequest {
  let body: [String: Any]
  init(_ body: [String: Any]) { self.body = body }
  static var invalid: WallpaperActionError {
    WallpaperActionError(
      message: String(
        localized: "This control sent an invalid value. Refresh the interface and retry."))
  }
  func string(_ key: String) throws -> String {
    guard let value = body[key] as? String, value.count <= 65_536 else { throw Self.invalid }
    return value
  }
  func boolean(_ key: String) throws -> Bool {
    guard let value = body[key] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else {
      throw Self.invalid
    }
    return value.boolValue
  }
  func number(_ key: String, range: ClosedRange<Double>) throws -> Double {
    guard let value = body[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
      value.doubleValue.isFinite, range.contains(value.doubleValue)
    else { throw Self.invalid }
    return value.doubleValue
  }
  /// Quality values are clamped rather than refused: every control only offers
  /// values inside the range, so an outlier means a stale page, and the user's
  /// intent (the nearest supported quality) is still unambiguous.
  func clampedNumber(_ key: String, to range: ClosedRange<Double>) throws -> Double {
    guard let value = body[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
      value.doubleValue.isFinite
    else { throw Self.invalid }
    return min(max(value.doubleValue, range.lowerBound), range.upperBound)
  }
  func scaling() throws -> BridgeScalingMode {
    switch try string("value") {
    case "none": .none
    case "stretch": .stretch
    case "match": .match
    case "fill": .fill
    default: throw Self.invalid
    }
  }
}
