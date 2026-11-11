import Foundation

/// What the inspector reads about the selected wallpaper's options and properties.
///
/// Everything here is derived on read from the stores and the panel's own overlay, and reads only
/// what it shows, so SwiftUI re-renders exactly when something it used changed. Nothing here
/// mutates observable state: the side effects the web panel ran while it built a snapshot (selecting
/// the compatibility and Black bars context, measuring a chosen folder) are
/// `reconcileInspectorContext()`'s, which an observation runs and a test calls by hand.
extension PanelController {
  /// The wallpaper the inspector shows: the selected one, when it is still installed.
  var selectedInstalledWallpaperID: String? {
    guard let id = store.appSnapshot.selectedWallpaperId,
      store.librarySnapshot.wallpapers.contains(where: { $0.id == id })
    else { return nil }
    return id
  }

  /// The options of `wallpaperID` as the inspector draws them, or nil while the bridge has not
  /// answered for it: the inspector shows "Loading wallpaper options…" until then.
  func inspectorOptions(for wallpaperID: String) -> InspectorOptions? {
    startInspectorContextObservation()
    guard let value = store.wallpaperOptionsSnapshot, value.wallpaperId == wallpaperID else {
      return nil
    }
    let settings = store.settingsSnapshot
    _ = store.webWallpaperDeliveryRevision
    var inputs = InspectorOptions.Inputs()
    inputs.titles = displayTitles.resolved()
    inputs.assets = assets(of: value)
    inputs.pathErrors = propertyPathErrors[wallpaperID] ?? [:]
    inputs.textDrafts = Dictionary(
      uniqueKeysWithValues: store.editorState.propertyTextDrafts
        .filter { $0.key.wallpaperID == wallpaperID }.map { ($0.key.fieldID, $0.value) })
    inputs.pendingValues = pendingPropertyValues[wallpaperID] ?? [:]
    inputs.pendingEngineValues = pendingEngineOptionValues[wallpaperID] ?? [:]
    inputs.delivery = store.webWallpaperDeliveryStatus?()
    inputs.sceneMedia = store.sceneMediaAvailability?()
    // The displays macOS's own video player draws this wallpaper on, which cannot be moved.
    inputs.nativePlayerDisplays = Set(
      settings.videoBackends.filter { $0.wallpaperId == wallpaperID && $0.backend == "native" }
        .map(\.displayId))
    inputs.frameRateCeiling = FrameRateCeiling(settings)
    inputs.isLocked = isInspectorLocked(for: wallpaperID)
    return InspectorOptions.make(value, inputs: inputs)
  }

  /// Whether the property controls of `wallpaperID` wait: a command is running or waiting, or the
  /// wallpaper is being applied or reverted. A property edit is itself a command, so this is on for
  /// the length of every edit; the web panel disabled the control being edited with the rest, which
  /// dropped its keyboard focus, so the inspector keeps the control that is being edited enabled and
  /// locks the others.
  func isInspectorLocked(for wallpaperID: String) -> Bool {
    isStoreBusy || isBusy(InspectorAction.apply(wallpaperID))
      || isBusy(InspectorAction.revert(wallpaperID))
  }

  // MARK: Text drafts

  /// A property's text as typed and not yet committed, or nil when there is none.
  func propertyTextDraft(_ propertyID: String, in wallpaperID: String) -> String? {
    store.editorState.propertyTextDrafts[.init(wallpaperID: wallpaperID, fieldID: propertyID)]
  }

  /// Keeps what the user is typing into a text property, on every keystroke. The text is a draft
  /// the wallpaper's Modified mark, the footer sentence, Apply and Revert, presets and Restore all
  /// already count; it reaches the bridge when committed (`commitProperty`: Return or leaving the
  /// field) or when Apply changes sends it. The panel's view state leaves drafts out on purpose: a
  /// draft restored against a library that changed in between could deliver a stale value.
  func setPropertyText(_ text: String, property propertyID: String, in wallpaperID: String) {
    store.editorState.setPropertyText(
      text, key: .init(wallpaperID: wallpaperID, fieldID: propertyID))
  }

  /// Drops every text draft of the wallpaper (what Restore all defaults and Revert do first).
  func discardPropertyTextDrafts(of wallpaperID: String) {
    for key in store.editorState.propertyTextDrafts.keys where key.wallpaperID == wallpaperID {
      store.editorState.clearPropertyText(key)
    }
  }

  // MARK: Measured files and folders

  /// What each enabled `file` / `directory` property of this wallpaper currently points at, keeping
  /// the measurement until the chosen path changes. Measuring a folder is a directory read and the
  /// inspector reads its state many times a second, so the answer is remembered; the panel closing
  /// throws the cache away and the next read measures once more, which is why the row survives a
  /// reopen without the panel holding the wallpaper's staged files open. A property a visibility
  /// rule hides is never read: a folder nobody can see is not measured.
  func measuredAssets(for options: BridgeWallpaperOptionsSnapshot) -> [String: PanelPropertyAsset] {
    var measured: [String: PanelPropertyAsset] = [:]
    for property in options.properties where property.enabled {
      guard let asset = asset(of: property, in: options, remembering: true) else { continue }
      measured[property.id] = asset
    }
    return measured
  }

  /// `measuredAssets` without remembering, for a read from a view: a cache miss is measured now and
  /// stored by `reconcileInspectorContext()` a turn later, never by the read itself.
  private func assets(of options: BridgeWallpaperOptionsSnapshot) -> [String: PanelPropertyAsset] {
    var measured: [String: PanelPropertyAsset] = [:]
    for property in options.properties where property.enabled {
      guard let asset = asset(of: property, in: options, remembering: false) else { continue }
      measured[property.id] = asset
    }
    return measured
  }

  private func asset(
    of property: BridgePropertyDescriptor, in options: BridgeWallpaperOptionsSnapshot,
    remembering: Bool
  ) -> PanelPropertyAsset? {
    guard property.kind == .file || property.kind == .directory,
      case .string(let path) = property.value, !path.isEmpty
    else { return nil }
    if let cached = propertyAssets[options.wallpaperId]?[property.id], cached.path == path {
      return cached
    }
    let asset = PanelPropertyAsset.measure(
      path: path, directory: property.kind == .directory,
      filter: PanelPropertyAsset.filter(for: property.fileFilter))
    if remembering { propertyAssets[options.wallpaperId, default: [:]][property.id] = asset }
    return asset
  }
}
