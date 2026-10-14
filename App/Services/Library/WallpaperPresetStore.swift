import Foundation
import Observation

struct WallpaperPresetError: LocalizedError, Equatable {
  let message: String
  var errorDescription: String? { message }
}

/// Bridge values deliberately use a separate Codable boundary, not generated bridge code.
enum WallpaperPresetValue: Codable, Equatable {
  case bool(Bool), number(Double), string(String), color(red: Double, green: Double, blue: Double), empty

  init(_ value: BridgePropertyValue) {
    switch value {
    case .bool(let value): self = .bool(value)
    case .number(let value): self = .number(value)
    case .string(let value): self = .string(value)
    case .colorRgb(let red, let green, let blue): self = .color(red: red, green: green, blue: blue)
    case .empty: self = .empty
    }
  }

  var bridgeValue: BridgePropertyValue {
    switch self {
    case .bool(let value): .bool(value: value)
    case .number(let value): .number(value: value)
    case .string(let value): .string(value: value)
    case .color(let red, let green, let blue): .colorRgb(red: red, green: green, blue: blue)
    case .empty: .empty
    }
  }
}

struct WallpaperPresetProperty: Codable, Equatable {
  var id: String
  var kind: String
  var value: WallpaperPresetValue
  /// Resolve against the current author's default, rather than baking in an old default.
  var usesDefault: Bool
  /// Only file/directory imports managed by the app get retained snapshots.
  var retainedPath: String?
}

struct WallpaperPropertyPreset: Codable, Equatable, Identifiable {
  var id: String
  var wallpaperID: String
  var name: String
  var properties: [WallpaperPresetProperty]
}

struct WallpaperPresetDocument: Codable {
  static let currentVersion = 1
  var version = currentVersion
  var preset: WallpaperPropertyPreset
  /// Managed bytes are portable; external references are not and cannot grant read access.
  var assets: [String: [Attachment]] = [:]
  struct Attachment: Codable {
    var name: String
    var bytes: Data
  }
}

struct WallpaperPresetMutation {
  enum Operation {
    case restoreDefault
    case value(BridgePropertyValue)
    case path(String?)
  }
  var propertyID: String
  var operation: Operation
}

@MainActor
@Observable
final class WallpaperPresetStore {
  static let shared = WallpaperPresetStore()
  static let preferenceKey = "WallpaperMachine.wallpaperPresets"
  static let didChangeNotification = Notification.Name("WallpaperMachine.wallpaperPresetsChanged")
  nonisolated static let retainedDirectoryName = "PresetAssets"
  nonisolated static let maximumDocumentBytes = 48 * 1024 * 1024
  nonisolated static let maximumAssetBytes = 32 * 1024 * 1024
  nonisolated static let maximumPresets = 512
  nonisolated static let maximumProperties = 512

  private struct Archive: Codable {
    var version = 1
    var items: [WallpaperPropertyPreset]
  }

  private(set) var items: [WallpaperPropertyPreset] = []
  private(set) var error: String?
  var status: String?
  @ObservationIgnored var chooseImportFile: (@MainActor () async -> URL?)?
  @ObservationIgnored var chooseExportFile: (@MainActor (String) async -> URL?)?
  @ObservationIgnored private let defaults: UserDefaults
  // Stateless IO dependencies are used only by utility jobs; published state stays MainActor-owned.
  @ObservationIgnored nonisolated(unsafe) private let managed: ManagedUserAssetStore
  @ObservationIgnored nonisolated private let fileManager: FileManager
  // Resolve from the current filesystem, not before the support directory exists:
  // Foundation's /private aliases can change when the managed root is published.
  nonisolated private var retentionRoot: URL {
    managed.root.resolvingSymlinksInPath().standardizedFileURL.appendingPathComponent(Self.retainedDirectoryName, isDirectory: true)
  }

  init(defaults: UserDefaults = ClientPreferences.defaults, managed: ManagedUserAssetStore = ManagedUserAssetStore(),
       fileManager: FileManager = .default) {
    self.defaults = defaults
    self.managed = managed
    self.fileManager = fileManager
    if let data = defaults.data(forKey: Self.preferenceKey) {
      do {
        try Self.validateArchiveData(data)
        let archive = try JSONDecoder().decode(Archive.self, from: data)
        items = archive.items
      } catch {
        self.error = String(localized: "Saved property presets could not be read. Restore a backup before saving new presets.")
      }
    }
  }

  nonisolated static func validateArchiveData(_ data: Data) throws {
    guard data.count <= maximumDocumentBytes else { throw invalidDocument() }
    let archive = try JSONDecoder().decode(Archive.self, from: data)
    guard archive.version == 1, archive.items.count <= maximumPresets,
          Set(archive.items.map { canonicalComponent($0.id) }).count == archive.items.count else { throw invalidDocument() }
    for preset in archive.items { try validateStructure(preset) }
  }

  func presets(wallpaperID: String) -> [WallpaperPropertyPreset] {
    items.filter { $0.wallpaperID == wallpaperID }
  }

  func preset(id: String) throws -> WallpaperPropertyPreset {
    guard let item = items.first(where: { $0.id == id }) else {
      throw WallpaperPresetError(message: String(localized: "This property preset no longer exists."))
    }
    return item
  }

  @discardableResult
  func save(name: String, options: BridgeWallpaperOptionsSnapshot, hasPendingEdits: Bool) async throws -> WallpaperPropertyPreset {
    try requireClean(options, hasPendingEdits: hasPendingEdits)
    guard items.count < Self.maximumPresets else { throw Self.invalidDocument() }
    // A preset keeps the properties the panel lists. One a visibility rule hides is not
    // part of it; applying the preset leaves that property as it is, unless the preset
    // itself opens the rule and names the property.
    let listed = options.properties.filter(\.enabled)
    if let unknown = listed.first(where: { $0.kind == .unknown }) {
      throw Self.invalidProperty(unknown.id)
    }
    let preset = WallpaperPropertyPreset(id: UUID().uuidString, wallpaperID: options.wallpaperId,
      name: try Self.validName(name), properties: listed.compactMap { descriptor in
        guard let kind = Self.kind(descriptor.kind) else { return nil }
        return WallpaperPresetProperty(id: descriptor.id, kind: kind, value: WallpaperPresetValue(descriptor.value),
          usesDefault: !descriptor.canRestoreDefaults, retainedPath: nil)
      })
    try Self.validateStructure(preset)
    let retained = try await Task.detached(priority: .utility) { try self.retainAssets(preset, options: options) }.value
    do {
      try publish(items + [retained])
      return retained
    } catch {
      await Task.detached(priority: .utility) { self.removeRetained(preset.id) }.value
      throw error
    }
  }

  nonisolated private func retainAssets(_ original: WallpaperPropertyPreset, options: BridgeWallpaperOptionsSnapshot) throws -> WallpaperPropertyPreset {
    var preset = original
    var total: Int64 = 0
    let manifest = try managed.manifest(wallpaperId: options.wallpaperId)
    do {
      for index in preset.properties.indices {
        let property = preset.properties[index]
        guard !property.usesDefault, property.kind == "file" || property.kind == "directory",
              let descriptor = options.properties.first(where: { $0.id == property.id }),
              descriptor.assetManaged else { continue }
        let record = manifest.properties[property.id]
        guard let record, !record.assets.isEmpty else { throw Self.missingAsset(property.id) }
        guard record.assets.count <= 4096,
              Set(record.assets.map { Self.canonicalComponent($0.fileName) }).count == record.assets.count else { throw Self.invalidDocument() }
        let directory = try prepareRetainedDirectory(presetID: preset.id, propertyID: property.id)
        for asset in record.assets {
          guard Self.safeComponent(asset.fileName) else { throw Self.invalidDocument() }
          let source = try managed.storedURL(wallpaperId: options.wallpaperId, propertyId: property.id, asset: asset)
          try requireRegularFile(source, propertyID: property.id)
          let size = Int64(try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
          guard size >= 0, size <= Int64(Self.maximumAssetBytes) - total else { throw Self.assetLimit() }
          total += size
          try ManagedUserAssetStore.copy(source, to: directory.appendingPathComponent(asset.fileName), fileManager: fileManager)
        }
        let retainedURL = property.kind == "directory"
          ? directory : directory.appendingPathComponent(record.assets[0].fileName)
        preset.properties[index].retainedPath = retainedURL.standardizedFileURL.path
        if record.originalSourceUnauthorized == true, let path = preset.properties[index].retainedPath {
          // Backup provenance is not an authorized live source. Save the actual
          // retained bytes, never prefer that original merely because it exists.
          preset.properties[index].value = .string(path)
        }
      }
      // Validation includes missing external files before a preset is made visible.
      _ = try mutations(for: preset, options: options)
      try writeOwner(preset)
      return preset
    } catch {
      removeRetained(preset.id)
      throw error
    }
  }

  func rename(id: String, name: String) throws {
    var updated = items
    guard let index = updated.firstIndex(where: { $0.id == id }) else { _ = try preset(id: id); return }
    updated[index].name = try Self.validName(name)
    try publish(updated)
  }

  func delete(id: String, preservingPaths: Set<String> = []) async throws {
    let removed = try preset(id: id)
    try publish(items.filter { $0.id != id })
    let savedIDs = Set(items.map(\.id))
    try await Task.detached(priority: .utility) {
      try self.pruneRetained(wallpaperID: removed.wallpaperID, savedIDs: savedIDs, preservingPaths: preservingPaths)
    }.value
  }

  func forget(wallpaperIDs: [String]) async throws {
    let removed = items.filter { wallpaperIDs.contains($0.wallpaperID) }
    try publish(items.filter { !wallpaperIDs.contains($0.wallpaperID) })
    try await Task.detached(priority: .utility) {
      for preset in removed { self.removeRetained(preset.id) }
      for id in wallpaperIDs { try self.pruneRetained(wallpaperID: id, savedIDs: [], preservingPaths: [], includeManagedReferences: false) }
    }.value
  }

  /// File/directory paths participate in the existing draft transaction. The
  /// immediate picker setter changes committed state and cannot be cancelled;
  /// EditProperty accepts the same kinds without publishing resource changes.
  func apply(_ preset: WallpaperPropertyPreset, options: BridgeWallpaperOptionsSnapshot, bridge: BridgeStore,
             userInitiated: Bool = false) async throws {
    try requireClean(options, hasPendingEdits: bridge.editorState.hasPendingEdits(wallpaperID: options.wallpaperId)
      || bridge.isWallpaperEditInProgress(id: options.wallpaperId))
    let mutations = try await Task.detached(priority: .utility) {
      try self.mutations(for: preset, options: options, allowConditional: true)
    }.value
    // Awaiting prevalidation cannot make an intervening editor change safe to discard.
    let actual = try await bridge.wallpaperOptionsSnapshotAsync(wallpaperId: options.wallpaperId)
    try requireClean(actual, hasPendingEdits: bridge.editorState.hasPendingEdits(wallpaperID: options.wallpaperId)
      || bridge.isWallpaperEditInProgress(id: options.wallpaperId))
    guard actual == options else {
      throw WallpaperPresetError(message: String(localized: "The wallpaper properties changed while preparing this preset. Refresh and retry."))
    }
    let selections = retainedSelections(preset, options: options, mutations: mutations)
    do {
      var remaining = mutations
      while !remaining.isEmpty {
        let current = try await bridge.wallpaperOptionsSnapshotAsync(wallpaperId: options.wallpaperId)
        let enabled = remaining.indices.filter { index in
          current.properties.contains { $0.id == remaining[index].propertyID && $0.enabled }
        }
        // Mode switches usually control the authored conditions. Re-read the bridge
        // after each draft edit so multi-stage dependencies are evaluated by its parser.
        guard let index = enabled.first(where: { index in
          current.properties.contains {
            $0.id == remaining[index].propertyID && ($0.kind == .bool || $0.kind == .combo)
          }
        }) ?? enabled.first else { throw Self.disabledProperty(remaining[0].propertyID) }
        let mutation = remaining.remove(at: index)
        switch mutation.operation {
        case .restoreDefault:
          try await bridge.restorePropertyDefaultAsync(wallpaperId: options.wallpaperId, propertyId: mutation.propertyID)
        case .path(let path):
          try await bridge.editPropertyAsync(wallpaperId: options.wallpaperId, propertyId: mutation.propertyID, value: .string(value: path ?? ""))
        case .value(let value):
          try await bridge.editPropertyAsync(wallpaperId: options.wallpaperId, propertyId: mutation.propertyID, value: value)
        }
      }
      let target = try await bridge.wallpaperOptionsSnapshotAsync(wallpaperId: options.wallpaperId)
      for mutation in mutations where !target.properties.contains(where: { $0.id == mutation.propertyID && $0.enabled }) {
        throw Self.disabledProperty(mutation.propertyID)
      }
      try await validateRetainedSelections(selections, preset: preset, options: options)
      try await UserAssetSelectionAuthorization.perform(managed: managed, wallpaperID: preset.wallpaperID, selections: selections) {
        if !mutations.isEmpty || !selections.isEmpty { try await bridge.applyWallpaperOptionsAsync(wallpaperId: options.wallpaperId, userInitiated: userInitiated) }
      }
    } catch {
      let original = error
      do { try await bridge.cancelWallpaperOptionsAsync(wallpaperId: options.wallpaperId) }
      catch {
        throw WallpaperPresetError(message: String(localized: "The property preset failed: \(original.localizedDescription). Pending preset edits could not be reverted: \(error.localizedDescription). Refresh and revert before continuing."))
      }
      throw original
    }
    do {
      let committed = try await bridge.wallpaperOptionsSnapshotAsync(wallpaperId: options.wallpaperId)
      try await pruneRetainedAssets(options: committed)
    } catch {
      throw WallpaperPresetError(message: String(localized: "Property preset applied, but unused retained assets could not be cleaned up: \(error.localizedDescription)."))
    }
  }

  private func retainedSelections(_ preset: WallpaperPropertyPreset, options: BridgeWallpaperOptionsSnapshot,
                                 mutations: [WallpaperPresetMutation]) -> [String: String] {
    var selections = [String: String]()
    for property in preset.properties {
      guard !property.usesDefault, let retained = property.retainedPath else { continue }
      if let mutation = mutations.first(where: { $0.propertyID == property.id }) {
        if case .path(let path) = mutation.operation, path == retained { selections[property.id] = retained }
      } else if let descriptor = options.properties.first(where: { $0.id == property.id }),
                case .string(let value) = descriptor.value, value == retained {
        selections[property.id] = retained
      }
    }
    return selections
  }

  private func validateRetainedSelections(_ selections: [String: String], preset: WallpaperPropertyPreset,
                                         options: BridgeWallpaperOptionsSnapshot) async throws {
    guard !selections.isEmpty else { return }
    try await Task.detached(priority: .utility) {
      for (propertyID, path) in selections {
        guard let property = preset.properties.first(where: { $0.id == propertyID }), property.retainedPath == path,
              let descriptor = options.properties.first(where: { $0.id == propertyID }) else { throw Self.invalidDocument() }
        // Neither original provenance nor an arbitrary root prefix is a grant.
        try self.validatePath(path, property: property, descriptor: descriptor, presetID: preset.id)
      }
    }.value
  }

  func requireClean(_ options: BridgeWallpaperOptionsSnapshot, hasPendingEdits: Bool) throws {
    guard options.supported, !options.dirty, !hasPendingEdits else {
      throw WallpaperPresetError(message: String(localized: "Apply or revert pending edits before saving or applying a property preset."))
    }
  }

  /// Validates values and assets before any edit. Conditional enablement can be
  /// deferred to the draft transaction, which reevaluates it after each mode change.
  nonisolated func mutations(for preset: WallpaperPropertyPreset, options: BridgeWallpaperOptionsSnapshot,
                            allowConditional: Bool = false) throws -> [WallpaperPresetMutation] {
    try Self.validateStructure(preset)
    guard preset.wallpaperID == options.wallpaperId else {
      throw WallpaperPresetError(message: String(localized: "This property preset belongs to a different wallpaper."))
    }
    var result: [WallpaperPresetMutation] = []
    let authority = try managed.manifest(wallpaperId: preset.wallpaperID).properties
    for property in preset.properties {
      guard let descriptor = options.properties.first(where: { $0.id == property.id }),
            Self.kind(descriptor.kind) == property.kind else {
        throw WallpaperPresetError(message: String(localized: "Preset property \(property.id) is unknown or its authored type has changed."))
      }
      let value = property.usesDefault ? WallpaperPresetValue(descriptor.defaultValue) : property.value
      try Self.validateValue(value, descriptor: descriptor)
      let current = WallpaperPresetValue(descriptor.value)
      if property.usesDefault {
        if descriptor.canRestoreDefaults {
          guard descriptor.enabled || allowConditional else { throw Self.disabledProperty(property.id) }
          result.append(.init(propertyID: property.id, operation: .restoreDefault))
        }
        continue
      }
      if property.kind == "file" || property.kind == "directory" {
        let path: String?
        switch value {
        case .empty: path = nil
        case .string(let string):
          let record = authority[property.id]
          let permitted = record?.originalSourceUnauthorized != true
            && (record?.authorizedSourcePath == nil || record?.authorizedSourcePath == URL(fileURLWithPath: string).standardizedFileURL.path)
          if string.isEmpty { path = nil }
          else if !permitted {
            // Do not even probe an unauthorized original's filesystem metadata.
            guard let retained = property.retainedPath else {
              throw WallpaperPresetError(message: String(localized: "External file references are not portable. Choose the files in the property editor and save a new preset."))
            }
            path = retained
          } else {
            // A locally-authorized live folder stays live; retained bytes are the
            // missing-source fallback, not a replacement for directory watching.
            path = fileManager.isReadableFile(atPath: string) ? string : property.retainedPath ?? string
          }
        default: throw Self.invalidProperty(property.id)
        }
        if let path { try validatePath(path, property: property, descriptor: descriptor, presetID: preset.id) }
        let selectedValue = path.map { WallpaperPresetValue.string($0) } ?? .empty
        let currentIsEmpty = current == .empty || current == .string("")
        let changed = path == nil ? !currentIsEmpty : selectedValue != current
        guard descriptor.enabled || !changed || allowConditional else {
          throw Self.disabledProperty(property.id)
        }
        if changed {
          result.append(.init(propertyID: property.id, operation: .path(path)))
        }
      } else if property.kind == "texture", case .string(let path) = value, path.hasPrefix("/") {
        try requireRegularFile(URL(fileURLWithPath: path), propertyID: property.id)
        if value != current {
          guard descriptor.enabled || allowConditional else { throw Self.disabledProperty(property.id) }
          result.append(.init(propertyID: property.id, operation: .value(value.bridgeValue)))
        }
      } else if value != current {
        guard descriptor.enabled || allowConditional else { throw Self.disabledProperty(property.id) }
        result.append(.init(propertyID: property.id, operation: .value(value.bridgeValue)))
      }
    }
    return result
  }

  func exportDocument(id: String) async throws -> Data {
    let preset = try preset(id: id)
    return try await Task.detached(priority: .utility) { try self.exportDocument(preset: preset) }.value
  }

  nonisolated private func exportDocument(preset: WallpaperPropertyPreset) throws -> Data {
    var document = WallpaperPresetDocument(preset: preset)
    var total = 0
    for index in document.preset.properties.indices {
      let property = document.preset.properties[index]
      guard let path = property.retainedPath else { continue }
      try requireRetainedPath(path, presetID: document.preset.id, propertyID: property.id)
      let url = URL(fileURLWithPath: path)
      let sources = property.kind == "directory"
        ? try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]).sorted { $0.lastPathComponent < $1.lastPathComponent }
        : [url]
      guard !sources.isEmpty, sources.count <= 4096,
            Set(sources.map { Self.canonicalComponent($0.lastPathComponent) }).count == sources.count else { throw Self.invalidDocument() }
      var attachments: [WallpaperPresetDocument.Attachment] = []
      for source in sources {
        try requireRegularFile(source, propertyID: property.id)
        let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size >= 0, size <= Self.maximumAssetBytes - total else { throw Self.assetLimit() }
        let bytes = try Data(contentsOf: source, options: .mappedIfSafe)
        guard bytes.count <= Self.maximumAssetBytes - total else { throw Self.assetLimit() }
        total += bytes.count
        attachments.append(.init(name: source.lastPathComponent, bytes: bytes))
      }
      document.assets[property.id] = attachments
      document.preset.properties[index].retainedPath = nil
      // A portable attachment does not disclose the user's original filesystem path.
      document.preset.properties[index].value = .string(property.kind == "directory" ? "" : url.lastPathComponent)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    let data = try encoder.encode(document)
    guard data.count <= Self.maximumDocumentBytes else { throw Self.assetLimit() }
    return data
  }

  @discardableResult
  func importDocument(_ data: Data, options: BridgeWallpaperOptionsSnapshot) async throws -> WallpaperPropertyPreset {
    guard items.count < Self.maximumPresets else { throw Self.invalidDocument() }
    let preset = try await Task.detached(priority: .utility) { try self.prepareImport(data, options: options) }.value
    do {
      try publish(items + [preset])
      return preset
    } catch {
      await Task.detached(priority: .utility) { self.removeRetained(preset.id) }.value
      throw error
    }
  }

  nonisolated private func prepareImport(_ data: Data, options: BridgeWallpaperOptionsSnapshot) throws -> WallpaperPropertyPreset {
    guard data.count <= Self.maximumDocumentBytes else { throw Self.invalidDocument() }
    var document: WallpaperPresetDocument
    do { document = try JSONDecoder().decode(WallpaperPresetDocument.self, from: data) }
    catch { throw Self.invalidDocument() }
    guard document.version == WallpaperPresetDocument.currentVersion else {
      throw WallpaperPresetError(message: String(localized: "This property preset uses an unsupported format version."))
    }
    try Self.validateStructure(document.preset)
    guard document.preset.wallpaperID == options.wallpaperId else {
      throw WallpaperPresetError(message: String(localized: "This property preset belongs to a different wallpaper."))
    }
    guard document.assets.keys.allSatisfy({ key in document.preset.properties.contains { $0.id == key && ($0.kind == "file" || $0.kind == "directory") && !$0.usesDefault } }) else { throw Self.invalidDocument() }
    var total = 0
    for property in document.preset.properties {
      // An imported JSON is not permission to access arbitrary external paths.
      guard property.retainedPath == nil else { throw Self.invalidDocument() }
      if property.kind == "texture", !property.usesDefault, case .string(let path) = property.value,
         path.hasPrefix("/") || path.hasPrefix("file:") {
        throw WallpaperPresetError(message: String(localized: "External file references are not portable. Choose the files in the property editor and save a new preset."))
      }
      if property.kind == "file" || property.kind == "directory", !property.usesDefault {
        if let files = document.assets[property.id] {
          guard !files.isEmpty, files.count <= 4096,
                property.kind != "file" || files.count == 1,
                Set(files.map { Self.canonicalComponent($0.name) }).count == files.count else { throw Self.invalidDocument() }
          for file in files {
            guard Self.safeComponent(file.name) else { throw Self.invalidDocument() }
            guard file.bytes.count <= Self.maximumAssetBytes - total else { throw Self.assetLimit() }
            total += file.bytes.count
          }
        } else if property.value != .empty && property.value != .string("") {
          throw WallpaperPresetError(message: String(localized: "External file references are not portable. Choose the files in the property editor and save a new preset."))
        }
      }
    }
    document.preset.id = UUID().uuidString
    do {
      for index in document.preset.properties.indices {
        let property = document.preset.properties[index]
        guard let files = document.assets[property.id] else { continue }
        let directory = try prepareRetainedDirectory(presetID: document.preset.id, propertyID: property.id)
        // The UUID root is unpublished staging. Exclusive creation also fails
        // closed for destination aliases beyond the portable NFC/case check.
        for file in files { try file.bytes.write(to: directory.appendingPathComponent(file.name), options: .withoutOverwriting) }
        let retainedURL = property.kind == "directory" ? directory : directory.appendingPathComponent(files[0].name)
        let path = retainedURL.standardizedFileURL.path
        document.preset.properties[index].retainedPath = path
        document.preset.properties[index].value = .string(path)
      }
      _ = try mutations(for: document.preset, options: options, allowConditional: true)
      try writeOwner(document.preset)
      return document.preset
    } catch {
      removeRetained(document.preset.id)
      throw error
    }
  }

  private func publish(_ updated: [WallpaperPropertyPreset]) throws {
    guard error == nil else { throw WallpaperPresetError(message: error!) }
    guard updated.count <= Self.maximumPresets else { throw Self.invalidDocument() }
    for preset in updated { try Self.validateStructure(preset) }
    let data = try JSONEncoder().encode(Archive(items: updated))
    guard data.count <= Self.maximumDocumentBytes else { throw Self.invalidDocument() }
    defaults.set(data, forKey: Self.preferenceKey)
    items = updated
    status = nil
    NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
  }

  nonisolated private static func kind(_ kind: BridgePropertyKind) -> String? {
    switch kind {
    case .bool: "bool"
    case .slider: "slider"
    case .combo: "combo"
    case .color: "color"
    case .textInput: "textInput"
    case .texture: "texture"
    case .file: "file"
    case .directory: "directory"
    default: nil
    }
  }

  nonisolated private static func validateValue(_ value: WallpaperPresetValue, descriptor: BridgePropertyDescriptor) throws {
    let valid: Bool
    switch (descriptor.kind, value) {
    case (.bool, .bool): valid = true
    case (.slider, .number(let number)):
      let min = descriptor.slider?.min ?? 0, max = descriptor.slider?.max ?? 1
      valid = number.isFinite && min.isFinite && max.isFinite && min <= max && number >= min && number <= max
    case (.combo, _): valid = descriptor.comboOptions.contains { WallpaperPresetValue($0.value) == value }
    case (.color, .color(let red, let green, let blue)):
      valid = [red, green, blue].allSatisfy { $0.isFinite && (0...1).contains($0) }
    case (.textInput, .string(let string)), (.texture, .string(let string)),
         (.file, .string(let string)), (.directory, .string(let string)):
      valid = string.count <= 65_536 && !string.contains("\0")
    case (.file, .empty), (.directory, .empty): valid = true
    default: valid = false
    }
    guard valid else { throw invalidProperty(descriptor.id) }
  }

  nonisolated private func validatePath(_ path: String, property: WallpaperPresetProperty, descriptor: BridgePropertyDescriptor, presetID: String) throws {
    guard path.hasPrefix("/") else { throw Self.missingAsset(property.id) }
    if path == property.retainedPath { try requireRetainedPath(path, presetID: presetID, propertyID: property.id) }
    let url = URL(fileURLWithPath: path)
    let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
    guard fileManager.isReadableFile(atPath: path) else { throw Self.missingAsset(property.id) }
    let filter: UserAssetFilter
    switch descriptor.fileFilter {
    case .image: filter = .image
    case .video: filter = .video
    case nil: filter = .any
    }
    if property.kind == "directory" {
      guard values?.isDirectory == true else { throw Self.missingAsset(property.id) }
      let files = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
      if path == property.retainedPath {
        guard !files.isEmpty, files.count <= 4096 else { throw Self.missingAsset(property.id) }
        for file in files {
          try requireRegularFile(file, propertyID: property.id)
          guard filter.allowedExtensions.contains(file.pathExtension.lowercased()) else { throw Self.invalidProperty(property.id) }
        }
      }
    } else {
      guard values?.isRegularFile == true, filter.allowedExtensions.contains(url.pathExtension.lowercased()) else { throw Self.invalidProperty(property.id) }
    }
  }

  nonisolated private func prepareRetainedDirectory(presetID: String, propertyID: String) throws -> URL {
    guard UUID(uuidString: presetID) != nil, Self.safeComponent(propertyID) else { throw Self.invalidDocument() }
    try fileManager.createDirectory(at: managed.root, withIntermediateDirectories: true)
    var directory = managed.root.resolvingSymlinksInPath().standardizedFileURL
    for component in [Self.retainedDirectoryName, presetID, propertyID] {
      directory.appendPathComponent(component, isDirectory: true)
      if fileManager.fileExists(atPath: directory.path) {
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw Self.invalidDocument() }
      } else {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
      }
      // Check published directories, not a not-yet-existing /private alias. Each
      // component is checked before descendants can be created through it.
      directory = directory.standardizedFileURL
      guard directory.resolvingSymlinksInPath().standardizedFileURL.path == directory.path else { throw Self.invalidDocument() }
    }
    return directory
  }

  nonisolated private func requireRetainedPath(_ path: String, presetID: String, propertyID: String) throws {
    let url = URL(fileURLWithPath: path).standardizedFileURL
    let root = retentionRoot.standardizedFileURL
    let relative = Array(url.pathComponents.dropFirst(root.pathComponents.count))
    guard url.pathComponents.starts(with: root.pathComponents), relative.count == 2 || relative.count == 3,
          UUID(uuidString: relative[0]) != nil, relative[1] == propertyID,
          relative[0] == presetID,
          url.resolvingSymlinksInPath().path == url.path else { throw Self.invalidDocument() }
  }

  nonisolated private func requireRegularFile(_ url: URL, propertyID: String) throws {
    let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard values?.isRegularFile == true, values?.isSymbolicLink != true,
          fileManager.isReadableFile(atPath: url.path) else { throw Self.missingAsset(propertyID) }
  }

  nonisolated private func removeRetained(_ id: String) {
    guard UUID(uuidString: id) != nil else { return }
    let root = retentionRoot
    let directory = root.appendingPathComponent(id, isDirectory: true)
    for url in [root, directory] {
      guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
            values.isDirectory == true, values.isSymbolicLink != true,
            url.resolvingSymlinksInPath().standardizedFileURL.path == url.standardizedFileURL.path else { return }
    }
    try? fileManager.removeItem(at: directory)
  }

  /// Saved presets and applied sources have independent lifetimes. Orphaned sources
  /// are reclaimed on apply/delete, never while a committed path or a still-serving
  /// managed manifest references them. Only current/reconciling property sources
  /// remain in addition to the bounded saved archive; these are imports, not cache.
  func pruneRetainedAssets(options: BridgeWallpaperOptionsSnapshot) async throws {
    let savedIDs = Set(items.map(\.id))
    let paths = Self.resourcePaths(options)
    try await Task.detached(priority: .utility) {
      try self.pruneRetained(wallpaperID: options.wallpaperId, savedIDs: savedIDs, preservingPaths: paths)
    }.value
  }

  nonisolated static func resourcePaths(_ options: BridgeWallpaperOptionsSnapshot) -> Set<String> {
    Set(options.properties.flatMap { property -> [String] in
      guard property.kind == .file || property.kind == .directory else { return [] }
      var paths = [String]()
      if case .string(let value) = property.value, !value.isEmpty { paths.append(value) }
      if let source = property.assetSourcePath, !source.isEmpty { paths.append(source) }
      return paths
    })
  }

  nonisolated private func writeOwner(_ preset: WallpaperPropertyPreset) throws {
    guard preset.properties.contains(where: { $0.retainedPath != nil }) else { return }
    let root = retentionRoot.appendingPathComponent(preset.id, isDirectory: true)
    try Data(preset.wallpaperID.utf8).write(to: root.appendingPathComponent(".wallpaper-id"), options: .atomic)
  }

  nonisolated private func pruneRetained(wallpaperID: String, savedIDs: Set<String>, preservingPaths: Set<String>,
                                       includeManagedReferences: Bool = true) throws {
    guard Self.safeComponent(wallpaperID) else { throw Self.invalidDocument() }
    var paths = preservingPaths
    if includeManagedReferences {
      paths.formUnion(try managed.manifest(wallpaperId: wallpaperID).properties.values.map(\.sourcePath))
    }
    let rootComponents = retentionRoot.resolvingSymlinksInPath().pathComponents
    var protectedIDs = savedIDs
    for path in paths {
      let components = URL(fileURLWithPath: path).resolvingSymlinksInPath().pathComponents
      guard components.starts(with: rootComponents), components.count > rootComponents.count else { continue }
      protectedIDs.insert(components[rootComponents.count])
    }
    guard fileManager.fileExists(atPath: retentionRoot.path) else { return }
    for directory in try fileManager.contentsOfDirectory(at: retentionRoot, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
      let id = directory.lastPathComponent
      guard UUID(uuidString: id) != nil, !protectedIDs.contains(id) else { continue }
      let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      let components = directory.resolvingSymlinksInPath().pathComponents
      guard values.isDirectory == true, values.isSymbolicLink != true,
            components.starts(with: rootComponents), components.count == rootComponents.count + 1,
            components.last == id else { throw Self.invalidDocument() }
      let owner = directory.appendingPathComponent(".wallpaper-id")
      guard let values = try? owner.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
            values.isRegularFile == true, values.isSymbolicLink != true,
            let size = values.fileSize, size >= 0, size <= 255,
            let data = try? Data(contentsOf: owner), String(data: data, encoding: .utf8) == wallpaperID else { continue }
      try fileManager.removeItem(at: directory)
    }
  }

  nonisolated private static func safeComponent(_ string: String) -> Bool {
    !string.isEmpty && !string.hasPrefix(".") && !string.contains("/") && !string.contains("\\") && !string.contains(":") && !string.contains("\0") && string.utf8.count <= 255
  }

  nonisolated private static func validName(_ name: String) throws -> String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 120, !trimmed.contains("\0") else {
      throw WallpaperPresetError(message: String(localized: "Enter a property preset name of 1–120 characters."))
    }
    return trimmed
  }

  nonisolated fileprivate static func validateStructure(_ preset: WallpaperPropertyPreset) throws {
    guard UUID(uuidString: preset.id) != nil, safeComponent(preset.wallpaperID),
          preset.properties.count <= maximumProperties,
          Set(preset.properties.map { canonicalComponent($0.id) }).count == preset.properties.count else { throw invalidDocument() }
    _ = try validName(preset.name)
    for property in preset.properties {
      guard safeComponent(property.id) else { throw invalidDocument() }
      let valid: Bool
      switch (property.kind, property.value) {
      case ("bool", .bool): valid = true
      case ("slider", .number(let number)): valid = number.isFinite
      case ("combo", .string(let string)), ("textInput", .string(let string)),
           ("texture", .string(let string)), ("file", .string(let string)), ("directory", .string(let string)):
        valid = string.count <= 65_536 && !string.contains("\0")
      case ("color", .color(let red, let green, let blue)):
        valid = [red, green, blue].allSatisfy { $0.isFinite && (0...1).contains($0) }
      case ("file", .empty), ("directory", .empty): valid = true
      default: valid = false
      }
      guard valid else { throw invalidProperty(property.id) }
      if let path = property.retainedPath {
        guard !property.usesDefault, property.kind == "file" || property.kind == "directory",
              path.hasPrefix("/"), !path.contains("\0"), path.utf8.count <= 4096 else { throw invalidDocument() }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.first?.isEmpty == true,
              components.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { throw invalidDocument() }
        let suffix = Array(components.suffix(property.kind == "directory" ? 3 : 4)).map(String.init)
        guard suffix.count == (property.kind == "directory" ? 3 : 4),
              suffix[0] == retainedDirectoryName, suffix[1] == preset.id, suffix[2] == property.id,
              suffix.allSatisfy(safeComponent) else { throw invalidDocument() }
      }
    }
  }

  nonisolated fileprivate static func canonicalComponent(_ name: String) -> String {
    name.precomposedStringWithCanonicalMapping.lowercased()
  }

  nonisolated private static func invalidDocument() -> WallpaperPresetError {
    WallpaperPresetError(message: String(localized: "This property preset document is invalid or exceeds the supported limits."))
  }
  nonisolated private static func invalidProperty(_ id: String) -> WallpaperPresetError {
    WallpaperPresetError(message: String(localized: "Preset property \(id) does not match the current authored values or limits."))
  }
  nonisolated private static func disabledProperty(_ id: String) -> WallpaperPresetError {
    WallpaperPresetError(message: String(localized: "Preset property \(id) is currently disabled. No preset changes were applied."))
  }
  nonisolated private static func missingAsset(_ id: String) -> WallpaperPresetError {
    WallpaperPresetError(message: String(localized: "Preset property \(id) references missing or unreadable assets. Choose the files again before applying."))
  }
  nonisolated private static func assetLimit() -> WallpaperPresetError {
    WallpaperPresetError(message: String(localized: "Portable property presets support up to 32 MB of managed assets. External files are not bundled."))
  }
}
