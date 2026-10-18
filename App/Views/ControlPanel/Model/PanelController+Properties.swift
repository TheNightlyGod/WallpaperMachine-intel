import AppKit
import Foundation
import UniformTypeIdentifiers

/// What a value dragged on a slider or colour control is, in a form the drag pump can carry.
enum PropertyDragValue: Equatable, Sendable {
  case number(Double)
  case color(red: Double, green: Double, blue: Double)

  var bridgeValue: BridgePropertyValue {
    switch self {
    case .number(let value): .number(value: value)
    case .color(let red, let green, let blue): .colorRgb(red: red, green: green, blue: blue)
    }
  }
}

/// The wallpaper's authored properties: committing a value, showing it while it is dragged, and
/// applying, reverting and restoring.
///
/// Edits are drafts held by the bridge until Apply changes: "Audio, scaling mode, position and
/// frame rate take effect immediately. Everything else is pending until committed." Text is the one
/// value the panel holds as a draft of its own before that (`setPropertyText`), in the editor state
/// the store already flushes when it applies.
extension PanelController {
  // MARK: Committing a value

  /// `property`: the value of one property, committed as a pending edit. Queued behind the user's
  /// other commands; start it with `.latestWins` under `InspectorAction.property`, so the newest
  /// value of a control lands last.
  ///
  /// Only an enabled property takes an edit, and the value is held to the rules of its control: a
  /// switch takes a boolean, a slider a number inside its range, a colour components from 0 to 1,
  /// text at most 65,536 characters, a choice one of its choices' values. `file` and `directory`
  /// properties are refused here: their path travels through `chooseAssetPath`.
  ///
  /// The row shows `value` from the moment the edit is asked for until it ends, so a control does
  /// not flicker back to the saved value while the edit waits its turn. A refusal leaves the row at
  /// the bridge's value (the web page left the refused value on show as a stale draft; it does not),
  /// except for typed text, which stays in its field for another try.
  func commitProperty(
    _ wallpaperID: String, property propertyID: String, value: BridgePropertyValue
  ) async throws {
    pendingPropertyValues[wallpaperID, default: [:]][propertyID] = value
    defer {
      if pendingPropertyValues[wallpaperID]?[propertyID] == value {
        pendingPropertyValues[wallpaperID]?[propertyID] = nil
        if pendingPropertyValues[wallpaperID]?.isEmpty == true {
          pendingPropertyValues[wallpaperID] = nil
        }
      }
    }
    try await run(.queued) {
      let id = try installedWallpaperID(wallpaperID)
      let options = try await store.wallpaperOptionsSnapshotAsync(wallpaperId: id)
      guard let descriptor = options.properties.first(where: { $0.id == propertyID && $0.enabled })
      else { throw InvalidControlValue() }
      let value = try Self.editableValue(value, for: descriptor)
      try await store.editPropertyAsync(wallpaperId: id, propertyId: propertyID, value: value)
    }
    // The text the bridge now holds is no longer a draft of the panel's, unless typing went on.
    if case .string(let sent) = value,
      propertyTextDraft(propertyID, in: wallpaperID) == sent
    {
      store.editorState.clearPropertyText(.init(wallpaperID: wallpaperID, fieldID: propertyID))
    }
    reconcileInspectorContext()
  }

  /// `propertyPreview`: the value a slider or colour is being dragged to, shown on the previews
  /// without being an edit. Not a command: it changes no state a later command depends on, and
  /// queued behind a running one it would reach the previews long after the thumb moved on. Leaves
  /// the banner alone, and a refusal throws to the caller (the drag pump ignores it); the release
  /// that ends the drag reports its own.
  ///
  /// Only enabled sliders and colours take part, and a value is held to the rules of an edit's.
  func previewProperty(
    _ wallpaperID: String, property propertyID: String, value: BridgePropertyValue
  ) async throws {
    try await run(.immediate) {
      let id = try installedWallpaperID(wallpaperID)
      let options = try await store.wallpaperOptionsSnapshotAsync(wallpaperId: id)
      guard let descriptor = options.properties.first(where: { $0.id == propertyID && $0.enabled }),
        descriptor.kind == .slider || descriptor.kind == .color
      else { throw InvalidControlValue() }
      let value = try Self.editableValue(value, for: descriptor)
      await store.previewPropertyAsync(wallpaperId: id, propertyId: propertyID, value: value)
    }
  }

  /// The pump for one slider or colour: a step shows the value being dragged, never throws, and
  /// ignores a refusal. The control calls `release(_:commit:)` with `commitProperty` inside
  /// `launch`, so a failure reaches the banner.
  ///
  /// - Parameters:
  ///   - interval, sleep: the pump's own, for a test that fires the clock by hand.
  func propertyDragPump(
    _ wallpaperID: String, property propertyID: String,
    interval: Duration = DragStepPump<PropertyDragValue>.defaultInterval,
    sleep: @escaping DragStepPump<PropertyDragValue>.Sleep = { try await Task.sleep(for: $0) }
  ) -> DragStepPump<PropertyDragValue> {
    DragStepPump(interval: interval, sleep: sleep) { [weak self] value in
      try? await self?.previewProperty(wallpaperID, property: propertyID, value: value.bridgeValue)
    }
  }

  /// The value a property's control may send, or the refusal for one it never offers.
  static func editableValue(_ value: BridgePropertyValue, for descriptor: BridgePropertyDescriptor)
    throws -> BridgePropertyValue
  {
    switch (descriptor.kind, value) {
    case (.bool, .bool):
      return value
    case (.slider, .number(let number)):
      let minimum = descriptor.slider?.min ?? 0
      let maximum = descriptor.slider?.max ?? 1
      guard number.isFinite, minimum <= maximum, (minimum...maximum).contains(number) else {
        throw InvalidControlValue()
      }
      return value
    // `file` and `directory` are excluded on purpose: their path travels through
    // `setPropertyPathAsync`, not through the generic property editor.
    case (.textInput, .string(let text)), (.texture, .string(let text)):
      guard text.count <= PanelValueRules.maximumTextLength else { throw InvalidControlValue() }
      return value
    case (.color, .colorRgb(let red, let green, let blue)):
      guard [red, green, blue].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
        throw InvalidControlValue()
      }
      return value
    case (.combo, _):
      guard let option = descriptor.comboOptions.first(where: { $0.value == value }) else {
        throw InvalidControlValue()
      }
      return option.value
    default:
      throw InvalidControlValue()
    }
  }

  // MARK: Apply, Revert, restore

  /// `apply`: Apply changes. Queued. The text the user typed and did not commit goes with it: the
  /// store sends the editor state's drafts as part of applying, and a draft longer than a text
  /// property takes is refused first, as its own edit would have been. Applying also ends a slider
  /// or colour step that is still shown.
  func apply(_ wallpaperID: String) async throws {
    try await run(.queued) {
      let id = try installedWallpaperID(wallpaperID)
      let drafts = store.editorState.propertyTextDrafts.filter { $0.key.wallpaperID == id }
      guard drafts.values.allSatisfy({ $0.count <= PanelValueRules.maximumTextLength }) else {
        throw InvalidControlValue()
      }
      try await store.applyWallpaperOptionsAsync(wallpaperId: id, userInitiated: true)
    }
    reconcileInspectorContext()
  }

  /// `revert`: Revert. Queued. The typed text goes first, as it did in the page, then the bridge
  /// puts the saved look back on the displays that showed an edit and discards the draft; a display
  /// that refuses keeps the edit so that Revert can be repeated.
  func revert(_ wallpaperID: String) async throws {
    discardPropertyTextDrafts(of: wallpaperID)
    try await run(.queued) {
      try await store.cancelWallpaperOptionsAsync(wallpaperId: installedWallpaperID(wallpaperID))
    }
    reconcileInspectorContext()
  }

  /// `restoreProperty`: stages the authored default of one property (pending: Apply keeps it,
  /// Revert undoes it). Its typed text is dropped first.
  func restoreProperty(_ wallpaperID: String, property propertyID: String) async throws {
    store.editorState.clearPropertyText(.init(wallpaperID: wallpaperID, fieldID: propertyID))
    try await run(.queued) {
      try await store.restorePropertyDefaultAsync(
        wallpaperId: installedWallpaperID(wallpaperID), propertyId: propertyID)
    }
  }

  /// `restoreAllProperties`: stages the default of every property except the files and folders the
  /// user chose, which keep their own Clear. It includes a value a visibility rule hides, and drops
  /// every text draft first. Display settings, audio and presets are not touched.
  func restoreAllProperties(_ wallpaperID: String) async throws {
    discardPropertyTextDrafts(of: wallpaperID)
    try await run(.queued) {
      try await store.restoreAllPropertyDefaultsAsync(
        wallpaperId: installedWallpaperID(wallpaperID))
    }
  }

  // MARK: Files, folders and images

  /// `choosePropertyFile`: a scene's image property. The picker stores the path of the image the
  /// user picks, not a copy, as a pending edit. Cancel changes nothing. Queued, with the picker open
  /// inside the turn as before. (Clearing the image is `commitProperty` with an empty string.)
  func chooseTextureImage(_ wallpaperID: String, property propertyID: String) async throws {
    try await run(.queued) {
      let id = try installedWallpaperID(wallpaperID)
      let options = try await store.wallpaperOptionsSnapshotAsync(wallpaperId: id)
      guard
        options.properties.contains(where: {
          $0.id == propertyID && $0.enabled && $0.kind == .texture
        })
      else { throw InvalidControlValue() }
      let panel = NSOpenPanel()
      panel.title = String(localized: "Choose Image")
      panel.allowedContentTypes = [.image]
      guard let url = await dialogs.choose(panel) else { return }
      try await store.editPropertyAsync(
        wallpaperId: id, propertyId: propertyID, value: .string(value: url.path))
    }
  }

  /// `choosePropertyPath`: the file or folder a `file` / `directory` property points at. Saved the
  /// moment it is picked (not a draft: each keeps its own Clear), through the app's selection
  /// authorization. A failure is recorded against the property, in `propertyPathErrors`, and not
  /// thrown: the window-wide banner cannot say which of several pickers failed.
  func chooseAssetPath(_ wallpaperID: String, property propertyID: String) async throws {
    try await changeAssetPath(wallpaperID, property: propertyID, choosing: true)
  }

  /// `clearPropertyPath`: forgets the chosen file or folder; the engine writes the default back.
  func clearAssetPath(_ wallpaperID: String, property propertyID: String) async throws {
    try await changeAssetPath(wallpaperID, property: propertyID, choosing: false)
  }

  private func changeAssetPath(_ wallpaperID: String, property propertyID: String, choosing: Bool)
    async throws
  {
    try await run(.queued) {
      let id = try installedWallpaperID(wallpaperID)
      let options = try await store.wallpaperOptionsSnapshotAsync(wallpaperId: id)
      guard let descriptor = options.properties.first(where: { $0.id == propertyID && $0.enabled }),
        descriptor.kind == .file || descriptor.kind == .directory
      else { throw InvalidControlValue() }
      propertyPathErrors[id]?[propertyID] = nil
      propertyAssets[id]?[propertyID] = nil
      guard choosing else {
        try await store.setPropertyPathAsync(wallpaperId: id, propertyId: propertyID, path: nil)
        return
      }
      let directory = descriptor.kind == .directory
      let label = PropertyLabels.plainLabel(descriptor.labelHtml)
      let panel = NSOpenPanel()
      panel.title = directory ? String(localized: "Choose Folder") : String(localized: "Choose File")
      panel.message =
        directory
        ? String(localized: "Choose a folder for \(label).")
        : String(localized: "Choose a file for \(label).")
      panel.canChooseDirectories = directory
      panel.canChooseFiles = !directory
      panel.canCreateDirectories = false
      if !directory {
        let types = PanelPropertyAsset.filter(for: descriptor.fileFilter).allowedExtensions.sorted()
          .compactMap { UTType(filenameExtension: $0) }
        if !types.isEmpty { panel.allowedContentTypes = types }
      }
      guard let url = await dialogs.choose(panel) else { return }
      if let reason = Self.stagingObstacle(wallpaperID: id) {
        propertyPathErrors[id, default: [:]][propertyID] = reason
        return
      }
      // The picker suspended: what the property is may have changed under it.
      let current = try await store.wallpaperOptionsSnapshotAsync(wallpaperId: id)
      guard
        current.properties.contains(where: {
          $0.id == propertyID && $0.enabled && $0.kind == descriptor.kind
        })
      else { throw InvalidControlValue() }
      // Only the extension is sandboxed, so this plain path stays readable across relaunches;
      // do not add security-scoped bookmarks.
      try await UserAssetSelectionAuthorization.perform(
        managed: ManagedUserAssetStore(), wallpaperID: id, selections: [propertyID: url.path]
      ) {
        try await store.setPropertyPathAsync(
          wallpaperId: id, propertyId: propertyID, path: url.path)
      }
    }
  }

  /// Why this wallpaper cannot hold a staged copy of a user-chosen file.
  ///
  /// WebKit only grants a page read access below its own project folder, so the file has to be
  /// staged inside it. A folder the app cannot write to defeats the choice before the engine ever
  /// sees it, and the user is owed that reason at the moment of picking.
  static func stagingObstacle(wallpaperID: String) -> String? {
    let project = ClientPaths.libraryURL.appendingPathComponent(wallpaperID)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: project.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      return L("This wallpaper’s folder is missing, so the file cannot be prepared for it.")
    }
    guard FileManager.default.isWritableFile(atPath: project.path) else {
      return L("This wallpaper’s folder is read-only, so the file cannot be prepared for it.")
    }
    return nil
  }
}
