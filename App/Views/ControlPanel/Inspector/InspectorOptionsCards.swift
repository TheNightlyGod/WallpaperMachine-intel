import SwiftUI

/// General configuration: the wallpaper's own audio and media settings. All of it is saved at once.
struct GeneralConfigurationCard: View {
  let options: InspectorOptions

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var showsStatus = false

  var body: some View {
    let id = options.wallpaperID
    let mutedKey = InspectorAction.wallpaperSetting(id, "muted")
    let volumeKey = InspectorAction.wallpaperSetting(id, "volume")
    let audioKey = InspectorAction.wallpaperSetting(id, "audioResponseEnabled")
    let mediaKey = InspectorAction.wallpaperSetting(id, "mediaIntegrationEnabled")
    InspectorSection("General configuration") {
      InspectorToggleRow(
        title: "Mute wallpaper audio", isOn: options.isMuted,
        isDisabled: controller.isInspectorControlDisabled(options, key: mutedKey)
      ) { muted in
        controller.launch(mutedKey, policy: .latestWins) { try await controller.setMuted(muted, for: id) }
      }
      InspectorSliderRow(
        title: "Volume", value: options.volume * 100, range: 0...100, step: 1,
        accessibilityLabel: L("Volume"), format: { InspectorWording.percent($0 / 100) },
        onRelease: { setVolume($0 / 100) }, onStep: { setVolume($0 / 100) }
      )
      .disabled(controller.isInspectorControlDisabled(options, key: volumeKey) || options.isMuted)
      InspectorToggleRow(
        title: "Audio response", isOn: options.audioResponseEnabled,
        isDisabled: controller.isInspectorControlDisabled(options, key: audioKey)
      ) { enabled in
        controller.launch(audioKey, policy: .latestWins) {
          try await controller.setAudioResponseEnabled(enabled, for: id)
        }
      }
      if options.offersMediaIntegration {
        InspectorToggleRow(
          title: "Media integration", isOn: options.mediaIntegrationEnabled,
          isDisabled: controller.isInspectorControlDisabled(options, key: mediaKey)
        ) { enabled in
          controller.launch(mediaKey, policy: .latestWins) {
            try await controller.setMediaIntegrationEnabled(enabled, for: id)
          }
        }
      }
      statusRow
    }
  }

  private func setVolume(_ fraction: Double) -> Task<Void, Never> {
    let id = options.wallpaperID
    return controller.launch(InspectorAction.wallpaperSetting(id, "volume"), policy: .latestWins) {
      try await controller.setVolume(fraction, for: id)
    }
  }

  // MARK: Audio and media status

  /// What the switches amount to: three facts that are never run into one sentence.
  private var statusRow: some View {
    VStack(alignment: .leading, spacing: 6) {
      Button {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { showsStatus.toggle() }
      } label: {
        HStack(spacing: 6) {
          Text("Audio and media status")
            .font(.system(size: 12.5))
            .foregroundStyle(theme.surface.muted.color)
          Spacer(minLength: 4)
          Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(theme.surface.muted.color)
            .rotationEffect(.degrees(showsStatus ? 90 : 0))
            .accessibilityHidden(true)
        }
        .frame(minHeight: 22)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityValue(showsStatus ? Text("Expanded") : Text("Collapsed"))
      if showsStatus {
        VStack(alignment: .leading, spacing: 6) {
          InspectorNote(
            "Reactive wallpapers use sound playing in other apps. macOS may request system audio recording permission."
          )
          status(InspectorWording.audioStatus(options))
          if options.offersMediaIntegration {
            InspectorNote(
              "Share song titles, artists and artwork from system Now Playing. Supports Spotify, Apple Music and compatible browsers and local players."
            )
            status(InspectorWording.mediaStatus(options))
          }
          if options.kind == .webpage, let output = options.delivery.webOutput {
            InspectorNote("Output controls are separate from system-audio response.")
            status(InspectorWording.webVolumeStatus(output.volume))
            status(InspectorWording.webMuteStatus(output.mute))
          }
        }
        .transition(.opacity)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func status(_ text: String) -> some View {
    Text(verbatim: text)
      .font(.system(size: 11.5, weight: .medium))
      .foregroundStyle(theme.surface.text.color)
      .frame(maxWidth: .infinity, alignment: .leading)
      .textSelection(.enabled)
      .announcing(text)
  }
}

// MARK: - Displays

/// Displays: one card for each display that plays the wallpaper, with its own playback settings.
struct DisplaysCard: View {
  let options: InspectorOptions

  var body: some View {
    InspectorSection("Displays", isOpen: InspectorPolicy.displaysOpenByDefault(options), card: false) {
      if options.displays.isEmpty {
        PanelCard {
          InspectorCardRow {
            InspectorNote("Apply this wallpaper to a display to configure playback.")
          }
        }
      } else {
        VStack(alignment: .leading, spacing: 12) {
          ForEach(options.displays) { display in
            DisplayCard(options: options, display: display)
          }
        }
      }
    }
  }
}

/// One display's playback of the wallpaper: Enabled, Scaling mode and Scale factor, Frame rate,
/// where the wallpaper sits, and Remove from display. Everything is saved at once except the Scale
/// factor, a draft that waits for Apply changes.
struct DisplayCard: View {
  let options: InspectorOptions
  let display: InspectorOptions.DisplayRow

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let id = options.wallpaperID
    let enabledKey = InspectorAction.displayConfig(id, display: display.id, "enabled")
    let modeKey = InspectorAction.displayConfig(id, display: display.id, "scalingMode")
    InspectorSection(verbatim: display.title, nested: true) {
      InspectorToggleRow(
        title: "Enabled", isOn: display.isEnabled,
        isDisabled: controller.isInspectorControlDisabled(options, key: enabledKey)
      ) { enabled in
        controller.launch(enabledKey, policy: .latestWins) {
          try await controller.setDisplayEnabled(enabled, on: display.id, for: id)
        }
      }
      InspectorRow("Scaling mode") {
        Picker(
          "",
          selection: Binding(
            get: { display.scalingMode },
            set: { mode in
              controller.launch(modeKey, policy: .latestWins) {
                try await controller.setScalingMode(mode, on: display.id, for: id)
              }
            })
        ) {
          Text("Original size").tag(BridgeScalingMode.none)
          Text("Stretch").tag(BridgeScalingMode.stretch)
          Text("Fit").tag(BridgeScalingMode.match)
          if InspectorPolicy.offersBlurredFit(options, display: display) {
            Text("Fit with blurred backdrop").tag(BridgeScalingMode.matchBlurred)
          }
          Text("Fill").tag(BridgeScalingMode.fill)
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
        .accessibilityLabel("Scaling mode")
      }
      .disabled(controller.isInspectorControlDisabled(options, key: modeKey))
      if InspectorPolicy.blurredFitNote(for: display) == .nativePlayer {
        InspectorCardRow {
          VStack(alignment: .leading, spacing: 4) {
            InspectorNote(
              "This video is drawn by the native video player, which leaves the bars black. Choose Compatibility for Video playback in Performance settings to blur them."
            )
            Button("Open Performance") {
              controller.launch("openSettings") { try await controller.openSettings(.performance) }
            }
            .buttonStyle(.inspectorLink)
          }
        }
      }
      ScaleFactorRow(options: options, display: display)
      // The native player plays a clip at the clip's own rate, so neither the display's frame rate
      // nor a ceiling on it applies to what it draws.
      if InspectorPolicy.offersFrameRate(for: display) {
        FrameRateRow(options: options, display: display)
        if let limit = display.frameRateLimit {
          InspectorCardRow {
            VStack(alignment: .leading, spacing: 4) {
              InspectorNote(verbatim: limit.note)
              Button(limit.section.openTitle) {
                controller.launch("openSettings") { try await controller.openSettings(limit.section) }
              }
              .buttonStyle(.inspectorLink)
            }
          }
        }
      }
      if options.offersPosition {
        PositionRows(options: options, display: display)
      }
      InspectorCardRow {
        Button {
          controller.launch(PanelActionCoordinator.key("eject", id: id, displayID: display.id)) {
            try await controller.eject(id, from: display.id)
          }
        } label: {
          Label("Remove from display", systemImage: "minus.circle")
        }
        .buttonStyle(.inspectorDestructiveLink)
        .disabled(options.isLocked)
      }
    }
  }
}

/// The scale factor is a number the person types: parsed in the panel's locale, held until Return or
/// the end of editing, and refused in place (never sent as 0) when it is not a finite number above
/// zero. It is a draft, so Apply changes saves it and Revert undoes it.
private struct ScaleFactorRow: View {
  let options: InspectorOptions
  let display: InspectorOptions.DisplayRow

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme
  @State private var text = ""
  @State private var issue: String?
  @FocusState private var isFocused: Bool

  var body: some View {
    let key = InspectorAction.displayConfig(options.wallpaperID, display: display.id, "scalingFactor")
    VStack(alignment: .leading, spacing: 4) {
      InspectorRow("Scale factor") {
        HStack(spacing: 4) {
          Text(verbatim: "×").font(.system(size: 12)).foregroundStyle(theme.surface.muted.color)
          TextField("Scale factor", text: $text)
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .multilineTextAlignment(.trailing)
            .frame(width: 76)
            .focused($isFocused)
            .onSubmit(commit)
            .accessibilityLabel("Scale factor")
        }
      }
      if let issue {
        Text(verbatim: issue)
          .font(.system(size: 11.5))
          .foregroundStyle(theme.surface.danger.color)
          .padding(.horizontal, 12)
          .padding(.bottom, 6)
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityAddTraits(.updatesFrequently)
      }
    }
    .disabled(controller.isInspectorControlDisabled(options, key: key))
    .onAppear { refresh() }
    .onChange(of: display.scalingFactor) { if !isFocused { refresh() } }
    .onChange(of: isFocused) { _, focused in if !focused { commit() } }
  }

  private func refresh() {
    text = display.scalingFactor.formatted(
      WallpaperEditorState.scalingFormat(locale: PanelLocale.shared.locale))
    issue = nil
  }

  private func commit() {
    guard let value = ScaleFactorInput.parse(text, locale: PanelLocale.shared.locale) else {
      issue = L("Enter a finite scaling factor greater than zero.")
      return
    }
    issue = nil
    guard value != display.scalingFactor else { return }
    let id = options.wallpaperID
    controller.launch(
      InspectorAction.displayConfig(id, display: display.id, "scalingFactor"), policy: .latestWins
    ) {
      try await controller.setScalingFactor(value, on: display.id, for: id)
    }
  }
}

/// The frame rate is a whole number from 1 to the display's own maximum: a field and a stepper, and a
/// typed value outside the range is held to it. Each step moves from the value on show, which is the
/// one last asked for until the renderer has answered (`FrameRateDraft`).
private struct FrameRateRow: View {
  let options: InspectorOptions
  let display: InspectorOptions.DisplayRow

  @Environment(PanelController.self) private var controller
  @State private var text = ""
  @State private var draft = FrameRateDraft()
  /// Counts finished saves, so the row looks at the renderer's value again from its current state
  /// (a task holds the row as it was when the save started).
  @State private var answers = 0
  @FocusState private var isFocused: Bool

  private var maximum: Int { max(1, display.maximumFrameRate) }

  var body: some View {
    let key = InspectorAction.displayConfig(options.wallpaperID, display: display.id, "fps")
    InspectorRow("Frame rate") {
      HStack(spacing: 4) {
        TextField("Frame rate", text: $text)
          .labelsHidden()
          .textFieldStyle(.roundedBorder)
          .controlSize(.small)
          .multilineTextAlignment(.trailing)
          .frame(width: 48)
          .focused($isFocused)
          .onSubmit { commit(FrameRateInput.parse(text, maximum: maximum)) }
          .accessibilityLabel("Frame rate")
        Stepper(
          "",
          value: Binding(
            get: { draft.shown(saved: display.frameRate) },
            set: { commit(FrameRateInput.clamp($0, maximum: maximum)) }),
          in: 1...maximum
        )
        .labelsHidden()
        .controlSize(.small)
        .accessibilityLabel("Frame rate")
      }
    }
    .disabled(controller.isInspectorControlDisabled(options, key: key))
    .onAppear { refresh() }
    .onChange(of: display.frameRate) { if !isFocused && !draft.isWaiting { refresh() } }
    .onChange(of: answers) { if !isFocused && !draft.isWaiting { refresh() } }
    .onChange(of: isFocused) { _, focused in
      if !focused { commit(FrameRateInput.parse(text, maximum: maximum)) }
    }
  }

  private func refresh() { text = String(draft.shown(saved: display.frameRate)) }

  private func commit(_ value: Int?) {
    guard let value else {
      refresh()
      return
    }
    text = String(value)
    guard value != draft.shown(saved: display.frameRate) else { return }
    draft.ask(value)
    let id = options.wallpaperID
    let task = controller.launch(
      InspectorAction.displayConfig(id, display: display.id, "fps"), policy: .latestWins
    ) {
      try await controller.setFrameRate(value, on: display.id, for: id)
    }
    // Saved, replaced by a newer step or refused: the row shows the renderer's value again once
    // nothing it asked for is on its way.
    Task { @MainActor in
      await task.value
      draft.answered(value)
      answers &+= 1
    }
  }
}

/// The value a Frame rate row shows and steps from: the one it last asked for while that is on its
/// way, then the renderer's again. Without it a second click of the stepper before the first save
/// lands would step from the old value and ask for the same rate twice (30, 31, 31 instead of 32).
struct FrameRateDraft: Equatable {
  /// The rate last asked for, until its save has finished.
  private(set) var asked: Int?

  var isWaiting: Bool { asked != nil }

  func shown(saved: Int) -> Int { asked ?? saved }

  mutating func ask(_ value: Int) { asked = value }

  /// The save of `value` finished, whatever came of it. One for an older value leaves the newer
  /// request waiting.
  mutating func answered(_ value: Int) {
    if asked == value { asked = nil }
  }
}

/// The text a Scale factor field accepts.
enum ScaleFactorInput {
  /// The factor in `text` as typed in `locale`, or nil unless it is a whole decimal number, finite
  /// and above zero. The same rules the editor state's scaling drafts use.
  @MainActor
  static func parse(_ text: String, locale: Locale) -> Double? {
    let state = WallpaperEditorState()
    let key = WallpaperEditorState.FieldKey(wallpaperID: "", fieldID: "")
    state.setScalingText(text, key: key, locale: locale)
    return state.scalingDrafts[key]?.value
  }
}

/// The text a Frame rate field accepts.
enum FrameRateInput {
  /// A whole number in `text` held to 1...maximum; nil for text that is not a whole number (an empty
  /// field never becomes 0).
  static func parse(_ text: String, maximum: Int) -> Int? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
      let value = Int(trimmed)
    else { return nil }
    return clamp(value, maximum: maximum)
  }

  static func clamp(_ value: Int, maximum: Int) -> Int { min(max(1, maximum), max(1, value)) }
}

// MARK: - Position

/// Where a scene or video sits on the display: two sliders, Center and a note. Saved the moment a
/// slider settles, and never disabled for a running command: its changes queue, and a disabled slider
/// would drop the keyboard focus the next arrow key needs.
private struct PositionRows: View {
  let options: InspectorOptions
  let display: InspectorOptions.DisplayRow

  @Environment(PanelController.self) private var controller
  @State private var horizontal = DriverBox<PumpedDrag<Double>>()
  @State private var vertical = DriverBox<PumpedDrag<Double>>()

  var body: some View {
    let id = options.wallpaperID
    let key = InspectorAction.displayPosition(id, display: display.id)
    InspectorSliderRow(
      title: "Horizontal position", value: display.position.x * 100, range: 0...100, step: 1,
      accessibilityLabel: L("Horizontal position"), format: { InspectorWording.percent($0 / 100) },
      onDrag: { drag(.horizontal).update($0 / 100) },
      onRelease: { drag(.horizontal).release($0 / 100) },
      onStep: { drag(.horizontal).step($0 / 100) })
    InspectorSliderRow(
      title: "Vertical position", value: display.position.y * 100, range: 0...100, step: 1,
      accessibilityLabel: L("Vertical position"), format: { InspectorWording.percent($0 / 100) },
      onDrag: { drag(.vertical).update($0 / 100) },
      onRelease: { drag(.vertical).release($0 / 100) },
      onStep: { drag(.vertical).step($0 / 100) })
    InspectorCardRow {
      VStack(alignment: .leading, spacing: 6) {
        Button {
          controller.launch(key, policy: .latestWins) {
            try await controller.resetDisplayPosition(id, display: display.id)
          }
        } label: {
          Label("Center", systemImage: "arrow.counterclockwise")
        }
        .buttonStyle(.inspectorLink)
        .disabled(display.position.isCentered)
        .help(L("Center the wallpaper on the display"))
        InspectorNote(
          "Choose which part of the wallpaper stays in view when it is larger than the display, or where it sits when it is smaller. Nothing moves when it already fits the display exactly."
        )
      }
    }
    // A drag cut off by the rows going away settles with its newest value.
    .onDisappear {
      horizontal.driver?.settle()
      vertical.driver?.settle()
    }
  }

  /// The driver of one axis: a pump of its own, the shared position key.
  private func drag(_ axis: PanelController.PositionAxis) -> PumpedDrag<Double> {
    let box = axis == .horizontal ? horizontal : vertical
    if let driver = box.driver { return driver }
    let driver = PumpedDrag<Double>.position(
      controller: controller, wallpaperID: options.wallpaperID, display: display.id, axis: axis)
    box.driver = driver
    return driver
  }
}
