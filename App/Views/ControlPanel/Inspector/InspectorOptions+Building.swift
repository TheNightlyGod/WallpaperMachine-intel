import Foundation

extension InspectorOptions {
  /// Everything besides the bridge's snapshot that the rows are built from.
  struct Inputs {
    var titles = ResolvedDisplayTitles(names: [:])
    /// Measured files and folders, by property id.
    var assets: [String: PanelPropertyAsset] = [:]
    /// Why choosing a path failed, by property id.
    var pathErrors: [String: String] = [:]
    /// Text typed into a property and not committed, by property id.
    var textDrafts: [String: String] = [:]
    /// Values just chosen that the bridge has not taken yet, by property id.
    var pendingValues: [String: BridgePropertyValue] = [:]
    /// Wallpaper Engine option values just chosen that the bridge has not taken yet.
    var pendingEngineValues: [BridgeEngineOptionId: BridgePropertyValue] = [:]
    var delivery: WebWallpaperHost.DeliveryStatus?
    var sceneMedia: SystemMediaAvailability?
    /// Physical display ids macOS's native video player draws this wallpaper on.
    var nativePlayerDisplays: Set<UInt32> = []
    /// The frame-rate ceiling in force and the setting that sets it.
    var frameRateCeiling: FrameRateCeiling?
    var isLocked = false
    /// The language the rows are worded in; the panel's own when nil.
    var locale: PanelLocale?
  }

  @MainActor
  static func make(_ value: BridgeWallpaperOptionsSnapshot, inputs: Inputs = Inputs())
    -> InspectorOptions
  {
    let id = value.wallpaperId
    return InspectorOptions(
      wallpaperID: id, kind: value.kind, isSupported: value.supported, isDirty: value.dirty,
      hasUnsentChanges: !inputs.textDrafts.isEmpty || !inputs.pendingValues.isEmpty
        || !inputs.pendingEngineValues.isEmpty,
      isLocked: inputs.isLocked, volume: Double(value.volume), isMuted: value.muted,
      audioResponseEnabled: value.audioResponseEnabled,
      mediaIntegrationEnabled: value.mediaIntegrationEnabled,
      hiddenModified: value.properties.contains {
        !$0.enabled && $0.dirty && $0.kind != .file && $0.kind != .directory
      },
      delivery: DeliveryReport.make(
        kind: value.kind, wallpaperID: id, host: inputs.delivery, sceneMedia: inputs.sceneMedia),
      displays: value.displayConfigurations.map { displayRow($0, inputs: inputs) },
      properties: value.properties.filter(\.enabled).map {
        propertyRow($0, wallpaperID: id, inputs: inputs)
      },
      engineOptions: value.engineOptions.map { options in
        options.rows.filter(\.enabled).map { engineRow($0, filters: options.imageFilters, inputs: inputs) }
      },
      engineHiddenModified: value.engineOptions?.rows.contains { !$0.enabled && $0.modified } ?? false)
  }

  private static func displayRow(_ row: BridgeDisplayConfigRow, inputs: Inputs) -> DisplayRow {
    let physicalID = ResolvedDisplayTitles.liveDisplayID(row.displayId, title: row.title)
    return DisplayRow(
      id: row.displayId, title: inputs.titles.title(row.title, displayId: row.displayId),
      isEnabled: row.enabled, scalingMode: row.scalingMode, scalingFactor: row.scalingFactor,
      frameRate: Int(row.targetFps), maximumFrameRate: Int(row.maxFps),
      position: Position(x: row.framing.panX, y: row.framing.panY),
      isDrawnByNativePlayer: physicalID.map { inputs.nativePlayerDisplays.contains($0) } ?? false,
      frameRateLimit: inputs.frameRateCeiling?.limiting(saved: Int(row.targetFps)))
  }

  @MainActor
  private static func propertyRow(
    _ property: BridgePropertyDescriptor, wallpaperID: String, inputs: Inputs
  ) -> PropertyRow {
    let locale = inputs.locale ?? .shared
    let label = PropertyLabels.presentation(
      labelHTML: property.labelHtml, wallpaperID: wallpaperID, locale: locale)
    let draft = property.kind == .textInput ? inputs.textDrafts[property.id] : nil
    let pending = inputs.pendingValues[property.id]
    let shown = pending ?? property.value
    let control: PropertyRow.Control
    switch property.kind {
    case .bool:
      if case .bool(let isOn) = shown {
        control = .toggle(isOn: isOn)
      } else {
        control = .toggle(isOn: false)
      }
    case .slider:
      let metadata = property.slider
      let minimum = metadata?.min ?? 0
      let value: Double
      if case .number(let number) = shown { value = number } else { value = minimum }
      control = .slider(
        PropertyRow.Slider(
          value: value, minimum: minimum, maximum: metadata?.max ?? 1,
          step: metadata.flatMap { $0.step > 0 ? $0.step : nil } ?? (metadata == nil ? 0.01 : nil),
          precision: Int(metadata?.precision ?? 0)))
    case .combo:
      let choices = property.comboOptions.enumerated().map { index, option in
        PropertyRow.Choice(
          id: index, label: PropertyLabels.choiceLabel(option.label, locale: locale),
          value: option.value)
      }
      control = .choice(
        selection: choices.first { $0.value == shown }?.value, choices: choices)
    case .color:
      if case .colorRgb(let red, let green, let blue) = shown {
        control = .color(red: red, green: green, blue: blue)
      } else {
        control = .color(red: 1, green: 1, blue: 1)
      }
    case .textInput:
      control = .text(draft ?? Self.string(shown))
    case .texture:
      control = .image(path: Self.string(shown))
    case .file:
      control = .file(pathState(property, inputs: inputs))
    case .directory:
      let asset = inputs.assets[property.id]
      control = .folder(
        pathState(property, inputs: inputs),
        PropertyRow.Folder(
          delivery: property.directoryMode == .fetchAll ? .wholeList : .onDemand,
          fileCount: asset?.matches, fileLimit: UserAssetStore.defaultDirectoryFileLimit,
          isTruncated: asset?.truncated ?? false))
    case .group:
      control = .heading
    case .text, .unknown:
      // A description record is its label; its value is shown too when it adds words.
      let detail = Self.string(shown)
      control = .description(
        detail: !detail.isEmpty && detail != PropertyLabels.plainWords(property.labelHtml)
          ? detail : nil)
    }
    return PropertyRow(
      id: property.id, control: control,
      name: label.text.isEmpty ? locale.string("Unnamed option") : label.text, label: label,
      isModified: property.dirty || draft != nil || pending != nil, isDirty: property.dirty,
      canRestoreDefault: property.defaultValue != .empty)
  }

  private static func pathState(_ property: BridgePropertyDescriptor, inputs: Inputs)
    -> PropertyRow.PathState
  {
    PropertyRow.PathState(
      name: inputs.assets[property.id]?.name,
      acceptedTypes: PanelPropertyAsset.filter(for: property.fileFilter).allowedExtensions.sorted(),
      error: inputs.pathErrors[property.id], isManaged: property.assetManaged,
      isMissing: property.assetMissing, sourcePath: property.assetSourcePath)
  }

  private static func string(_ value: BridgePropertyValue) -> String {
    if case .string(let text) = value { text } else { "" }
  }
}
