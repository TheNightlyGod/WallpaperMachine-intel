import Foundation

/// The selected wallpaper's options as the inspector draws them: its audio and media switches, one
/// card per display, and the authored property rows.
///
/// Built by `PanelController.inspectorOptions(for:)` from the bridge's options snapshot and the
/// panel's own overlay (text typed but not committed, a value chosen but not yet saved, the
/// measured files and folders, the delivery report of the running host), so a control always shows
/// what the user last did. `make` is the pure factory the tests drive.
struct InspectorOptions: Equatable {
  let wallpaperID: String
  let kind: BridgeWallpaperKind
  /// False for a wallpaper this Mac cannot render: everything stays visible, but Apply, Restore all
  /// and the position rows are unavailable.
  let isSupported: Bool
  /// The bridge holds edits Apply changes would save and Revert would undo.
  let isDirty: Bool
  /// Text typed into a property, or a value just chosen, that the bridge has not taken yet.
  let hasUnsentChanges: Bool
  /// A command is running or waiting, or this wallpaper is being applied or reverted: every control
  /// that changes the wallpaper's properties waits, except the Position sliders and Center, which
  /// queue (a disabled slider would drop the keyboard focus the next arrow key needs).
  let isLocked: Bool
  /// The wallpaper's own volume, from 0 to 1.
  let volume: Double
  let isMuted: Bool
  /// The user's settings; the delivery report never overwrites them.
  let audioResponseEnabled: Bool
  let mediaIntegrationEnabled: Bool
  /// A value that a visibility rule hides is modified: the inspector is not given its row, yet the
  /// value still reaches the wallpaper, so Restore all defaults has to know of it.
  let hiddenModified: Bool
  let delivery: DeliveryReport
  let displays: [DisplayRow]
  /// The enabled properties in the author's order. A property a visibility rule hides is not
  /// listed. Group and description rows can still have no words: the inspector's label renderer
  /// decides that and leaves them out.
  let properties: [PropertyRow]

  /// Whether Apply changes and Revert have anything to act on.
  var hasChanges: Bool { isDirty || hasUnsentChanges }
  var canRevert: Bool { !isLocked && hasChanges }
  var canApply: Bool { !isLocked && hasChanges && isSupported }

  /// Restore all defaults stages every default except chosen files and folders, which keep their
  /// own Clear. A modified value behind a hiding rule counts, though its row is not listed.
  var canRestoreAll: Bool {
    guard !isLocked, isSupported else { return false }
    return hasUnsentChanges || hiddenModified
      || properties.contains { $0.isDirty && !$0.control.isChosenPath }
  }

  /// Scene and video wallpapers can be moved on a display; a still image page is a web wallpaper and
  /// keeps its own Position on screen, and a web page always fills its window.
  var offersPosition: Bool {
    isSupported && (kind == .projectScene || kind == .video)
  }

  /// Whether Media integration is offered: only for the wallpaper kinds that can read track details.
  var offersMediaIntegration: Bool { kind == .webpage || kind == .projectScene }
}

// MARK: - Displays

extension InspectorOptions {
  /// One display's playback of this wallpaper. Enabled, Scaling mode and Frame rate are saved at
  /// once; the Scale factor is a draft that waits for Apply changes.
  struct DisplayRow: Equatable, Identifiable {
    let id: String
    let title: String
    let isEnabled: Bool
    let scalingMode: BridgeScalingMode
    let scalingFactor: Double
    let frameRate: Int
    /// The highest frame rate the display offers; 0 when it did not say.
    let maximumFrameRate: Int
    let position: Position
    /// macOS's own video player draws this wallpaper on the display, at the clip's own frame rate,
    /// so the display's frame rate and any ceiling on it do not apply to it.
    let isDrawnByNativePlayer: Bool
    /// The frame-rate ceiling in force, and what sets it, when it is below the saved frame rate.
    let frameRateLimit: FrameRateCeiling?
  }

  /// Where the wallpaper sits on a display: fractions from 0 (left, top) to 1 (right, bottom) of
  /// the room the display leaves around it.
  struct Position: Equatable {
    let x: Double
    let y: Double

    static let centered = Position(x: 0.5, y: 0.5)
    var isCentered: Bool { x == 0.5 && y == 0.5 }

    /// A value from the bridge held to 0...1; one that is not a number reads as centred.
    init(x: Double, y: Double) {
      func clamped(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0.5 }
      self.x = clamped(x)
      self.y = clamped(y)
    }
  }
}

// MARK: - Properties

extension InspectorOptions {
  /// One authored property: how to draw its control, what it is called, and whether it differs from
  /// what the wallpaper is using.
  struct PropertyRow: Equatable, Identifiable {
    enum Control: Equatable {
      case toggle(isOn: Bool)
      /// A slider. `step` is nil when the author gave none (any value); `precision` is how many
      /// decimals the author means the value to carry, which the web panel did not use.
      case slider(Slider)
      /// A pop-up of the author's choices. `selection` is the choice the current value matches, and
      /// nil when it matches none: show no selection, and never change the value on its own.
      case choice(selection: BridgePropertyValue?, choices: [Choice])
      case color(red: Double, green: Double, blue: Double)
      case text(String)
      /// A scene's image picker: the path of the picked image, empty for none. The picker stores
      /// the path, not a copy.
      case image(path: String)
      case file(PathState)
      case folder(PathState, Folder)
      /// A description record; `detail` is its value when that adds words to the label.
      case description(detail: String?)
      /// A heading that names the controls after it.
      case heading

      /// Whether this is a chosen file or folder, which keeps its own Clear.
      var isChosenPath: Bool {
        switch self {
        case .file, .folder: true
        default: false
        }
      }
    }

    struct Slider: Equatable {
      let value: Double
      let minimum: Double
      let maximum: Double
      let step: Double?
      let precision: Int
    }

    struct Choice: Equatable, Identifiable {
      /// The choice's place in the author's list: two choices may carry the same value.
      let id: Int
      let label: String
      let value: BridgePropertyValue
    }

    /// A chosen file or folder, reduced to what the row shows. Names and paths are
    /// attacker-influenced: show them with `Text(verbatim:)`.
    struct PathState: Equatable {
      /// The chosen item's own name; nil when nothing is chosen. The staged path the wallpaper
      /// reads is never shown.
      let name: String?
      /// The extensions the property accepts, sorted.
      let acceptedTypes: [String]
      /// Why choosing failed (a staging obstacle), shown beside this control and not in the banner.
      let error: String?
      /// The app keeps its own copy (true), or the wallpaper reads the file where it is (false).
      let isManaged: Bool
      /// A chosen item that is no longer there; reselect it.
      let isMissing: Bool
      /// The user's original pick, for recognising an external reference.
      let sourcePath: String?

      var isChosen: Bool { name != nil }
    }

    struct Folder: Equatable {
      enum Delivery: Equatable {
        /// The wallpaper receives the whole list of files.
        case wholeList
        /// The wallpaper picks files from the folder itself.
        case onDemand
      }
      let delivery: Delivery
      /// Files the import would take; nil when the folder could not be read, which is unknown and
      /// not zero.
      let fileCount: Int?
      let fileLimit: Int
      /// The folder holds more than `fileLimit` matching files; the first `fileLimit` are used.
      let isTruncated: Bool
    }

    let id: String
    let control: Control
    /// What names the control: the label's words, or "Unnamed option" for a label that is pure
    /// decoration. Never the editor's id.
    let name: String
    let label: PropertyLabels.Presentation
    /// The bridge reports the value as changed, or there is a draft or a value on its way.
    let isModified: Bool
    /// The bridge reports this property as changed (not counting the panel's own overlay).
    let isDirty: Bool
    /// The author gave a default, so Restore default is offered.
    let canRestoreDefault: Bool
  }
}

// MARK: - Delivery

extension InspectorOptions {
  /// What the panel can say about audio and media reaching a wallpaper. Three claims stay apart for
  /// both: what the user switched on, whether anything is delivered, and whether the panel can tell
  /// at all. "Cannot tell" and "available" are both naturally an absent value, so each has a case
  /// of its own.
  struct DeliveryReport: Equatable {
    enum Audio: Equatable {
      /// No host is running for web wallpapers: nothing was observed.
      case unknown
      /// A host is running but has nothing for this wallpaper.
      case inactive
      /// The wallpaper never asked for audio.
      case idle
      case connecting
      /// Subscribed; the first audio frame has not arrived.
      case subscribed
      /// A confirmed audio frame reached the wallpaper.
      case delivering
      case failed
    }

    enum Media: Equatable {
      case unknown
      case available
      /// The system cannot say what is playing; `reason` is its own words, if it gave any.
      case unavailable(reason: String?)
    }

    /// How far the Volume control reaches into a web page, and whether Mute silences all of it.
    struct WebOutput: Equatable {
      enum Volume: Equatable {
        /// Volume sets the audio and video the page plays through media elements.
        case mediaElements
        case unavailable
        case unknown
      }
      enum Mute: Equatable {
        /// Mute silences the whole page, Web Audio included.
        case available
        case unavailable
        case unknown
      }
      let volume: Volume
      let mute: Mute
    }

    let audio: Audio
    let media: Media
    /// Present for web wallpapers only.
    let webOutput: WebOutput?

    /// What the report says with no running host.
    static let unobserved = DeliveryReport(audio: .unknown, media: .unknown, webOutput: nil)

    /// Only a running host can say whether anything is delivered. A scene wallpaper's media comes
    /// from the system's own availability instead of the host's.
    static func make(
      kind: BridgeWallpaperKind, wallpaperID: String, host: WebWallpaperHost.DeliveryStatus?,
      sceneMedia: SystemMediaAvailability?
    ) -> DeliveryReport {
      var audio = Audio.unknown
      var media = Media.unknown
      if let host {
        if let state = host.audioStates[wallpaperID] {
          switch state {
          case .idle: audio = .idle
          case .failed: audio = .failed
          case .connecting: audio = .connecting
          case .subscribed: audio = .subscribed
          case .delivering: audio = .delivering
          }
        } else {
          audio = .inactive
        }
        media = host.mediaUnavailableReason.map { .unavailable(reason: $0) } ?? .available
      }
      if kind == .projectScene, let sceneMedia {
        switch sceneMedia {
        case .available: media = .available
        case .unavailable(let reason): media = .unavailable(reason: reason)
        }
      }
      var webOutput: WebOutput?
      if kind == .webpage {
        let controls = host?.audioOutputControls[wallpaperID]
        webOutput = WebOutput(
          volume: controls.map { $0.mediaVolume ? .mediaElements : .unavailable } ?? .unknown,
          mute: controls.map { $0.pageMute ? .available : .unavailable } ?? .unknown)
      }
      return DeliveryReport(audio: audio, media: media, webOutput: webOutput)
    }
  }
}

// MARK: - Building

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
      hasUnsentChanges: !inputs.textDrafts.isEmpty || !inputs.pendingValues.isEmpty,
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
      })
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
