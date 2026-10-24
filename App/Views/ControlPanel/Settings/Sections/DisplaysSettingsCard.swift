import SwiftUI

/// One display's card on Settings › Displays: its name, the switch and the mode, the wallpaper or
/// the mirror source, and the disclosures for its playlist, copy or swap, automatic selection and
/// playback.
///
/// Everything in the card is disabled while a wallpaper command runs, and while the display is off.
/// During a search the card shows only what the search keeps of it on this display
/// (`DisplaysCardSearch`), and nothing at all when that is nothing.
struct DisplaysSettingsCard: View {
  let display: DisplayRow

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let card = DisplaysCardSearch.make(display, controller: controller)
    if card.showsCard {
      VStack(alignment: .leading, spacing: 6) {
        header
        PanelCard {
          DisplaysBasicRows(display: display, forced: card.forced)
          if !display.isMirror { DisplaysPlaylistDisclosure(display: display, card: card) }
          DisplaysTransferDisclosure(display: display, card: card)
          DisplaysAutomationDisclosure(display: display, card: card)
          DisplaysPlaybackDisclosure(display: display, card: card)
        }
      }
    }
  }

  private var header: some View {
    HStack(spacing: 6) {
      Image(systemName: "display")
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(theme.surface.muted.color)
        .accessibilityHidden(true)
      Text(verbatim: display.title)
        .font(.system(size: 13, weight: .semibold))
        .lineLimit(1)
        .truncationMode(.tail)
      if display.isPrimary {
        Text("Primary display")
          .font(.system(size: 11.5))
          .foregroundStyle(theme.surface.muted.color)
          .lineLimit(1)
      }
    }
    .padding(.leading, 12)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isHeader)
  }
}

// MARK: - The always-visible rows

struct DisplaysBasicRows: View {
  let display: DisplayRow
  let forced: Bool

  @Environment(PanelController.self) private var controller

  var body: some View {
    let model = controller.displaysSettings
    let busy = controller.isStoreBusy
    let off = busy || !display.enabled
    let label = { (title: LocalizedStringResource) in
      L("\(controller.settings.text(title)) for \(display.title)")
    }

    DisplaysRow(
      item: DisplaysSettingsSection.enable, forced: forced, identity: display.id,
      controlLabel: label(DisplaysSettingsSection.enable.title)
    ) {
      Toggle(
        noLabel,
        isOn: model.binding(
          PanelActionCoordinator.key("displaySetting", id: display.id, detail: "enabled"),
          current: display.enabled
        ) { enabled in try await controller.setDisplay(display.id, .enabled(enabled)) }
      )
      .toggleStyle(.switch)
      .labelsHidden()
      .disabled(busy || display.isPrimary)
    }

    DisplaysRow(
      item: DisplaysSettingsSection.mode, forced: forced, identity: display.id,
      controlLabel: label(DisplaysSettingsSection.mode.title)
    ) {
      let mode = model.binding(
        PanelActionCoordinator.key("displaySetting", id: display.id, detail: "mode"),
        current: display.mode
      ) { mode in try await controller.setDisplay(display.id, .mode(mode)) }
      DisplaysTitleMenu(
        selection: mode, title: mode.wrappedValue == .mirror ? L("Mirror another display") : L("Independent"),
        width: 190
      ) {
        Text("Independent").tag(BridgeDisplayMode.standalone)
        Text("Mirror another display").tag(BridgeDisplayMode.mirror)
      }
      .disabled(off || display.isPrimary)
    }

    if display.isMirror {
      DisplaysRow(
        item: DisplaysSettingsSection.mirrorSource,
        note: display.mirrorTargets.isEmpty ? nil : "", forced: forced, identity: display.id,
        controlLabel: label(DisplaysSettingsSection.mirrorSource.title)
      ) {
        DisplaysTitleMenu(
          selection: model.binding(
            PanelActionCoordinator.key("displaySetting", id: display.id, detail: "mirrorTarget"),
            current: display.mirrorTarget ?? ""
          ) { target in
            // The empty entry is a prompt, not a choice: it sends nothing.
            guard !target.isEmpty else { return }
            try await controller.setDisplay(display.id, .mirrorTarget(target))
          },
          title: display.mirrorTargets.first { $0.id == display.mirrorTarget }?.title
            ?? L("Choose display")
        ) {
          Text("Choose display").tag("")
          ForEach(display.mirrorTargets) { Text(verbatim: $0.title).tag($0.id) }
        }
        .disabled(off || display.mirrorTargets.isEmpty)
      }
    } else {
      DisplaysRow(
        item: DisplaysSettingsSection.wallpaper, note: "",
        details: [display.wallpaperTitle ?? L("None selected")], forced: forced, identity: display.id,
        controlLabel: label(DisplaysSettingsSection.wallpaper.title), labelsControl: false
      ) {
        HStack(spacing: 8) {
          Button("Choose…") {
            controller.launch(PanelActionCoordinator.key("chooseDisplayWallpaper", id: display.id)) {
              try await controller.chooseDisplayWallpaper(on: display.id)
            }
          }
          .disabled(off)
          Button("Eject") {
            guard let wallpaper = display.wallpaperID else { return }
            controller.launch(PanelActionCoordinator.key("eject", id: display.id)) {
              try await controller.eject(wallpaper, from: display.id)
            }
          }
          .disabled(off || display.wallpaperID == nil)
        }
      }
      DisplaysDesktopRows(display: display, forced: forced)
    }
  }
}

// MARK: - Playback and scaling

struct DisplaysPlaybackDisclosure: View {
  let display: DisplayRow
  let card: DisplaysCardSearch

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let model = controller.displaysSettings
    let busy = controller.isStoreBusy
    let off = busy || !display.enabled
    let forced = card.forced
    // A standalone display's playback belongs to its wallpaper, so it needs one; a mirror has its own.
    let playbackOff = off || !display.canAdjustPlayback
    let label = { (title: LocalizedStringResource) in
      L("\(controller.settings.text(title)) for \(display.title)")
    }
    let maxFps = Int(max(1, display.maxFps))

    DisplaysDisclosure(item: DisplaysSettingsSection.playback, display: display.id, card: card) {
      if !display.isMirror && display.wallpaperID == nil {
        DisplaysNote(text: L("Choose a wallpaper to adjust playback."))
      }

      DisplaysRow(
        item: DisplaysSettingsSection.scaling, forced: forced, identity: display.id,
        controlLabel: label(DisplaysSettingsSection.scaling.title)
      ) {
        let scaling = model.binding(
          PanelActionCoordinator.key("displaySetting", id: display.id, detail: "scalingMode"),
          current: display.scalingMode
        ) { mode in try await controller.setDisplay(display.id, .scalingMode(mode)) }
        DisplaysTitleMenu(
          selection: scaling,
          title: {
            switch scaling.wrappedValue {
            case .none: L("No scaling")
            case .stretch: L("Stretch")
            case .match: L("Match")
            case .fill: L("Fill")
            case .matchBlurred: L("Match with blurred backdrop")
            }
          }(), width: 210
        ) {
          Text("No scaling").tag(BridgeScalingMode.none)
          Text("Stretch").tag(BridgeScalingMode.stretch)
          Text("Match").tag(BridgeScalingMode.match)
          Text("Match with blurred backdrop").tag(BridgeScalingMode.matchBlurred)
          Text("Fill").tag(BridgeScalingMode.fill)
        }
        .disabled(playbackOff)
      }

      DisplaysRow(
        item: DisplaysSettingsSection.scaleFactor, forced: forced, identity: display.id,
        controlLabel: label(DisplaysSettingsSection.scaleFactor.title)
      ) {
        DisplaysNumberField(
          value: display.scalingFactor, digits: 4, unit: "×",
          accepts: { $0 > 0 }, invalidMessage: L("Enter a number greater than 0."),
          commit: { factor in
            await controller.launch(
              PanelActionCoordinator.key("displaySetting", id: display.id, detail: "scalingFactor")
            ) { try await controller.setDisplay(display.id, .scalingFactor(factor)) }.value
          }
        )
        .disabled(playbackOff)
      }

      DisplaysRow(
        item: DisplaysSettingsSection.frameRate, forced: forced, identity: display.id,
        controlLabel: label(DisplaysSettingsSection.frameRate.title)
      ) {
        DisplaysNumberField(
          value: Double(display.fps), integer: true, digits: 0, unit: "fps",
          accepts: { (1...Double(maxFps)).contains($0) },
          invalidMessage: L("Enter a whole number from 1 to \(maxFps)."),
          commit: { fps in
            await controller.launch(
              PanelActionCoordinator.key("displaySetting", id: display.id, detail: "fps")
            ) { try await controller.setDisplay(display.id, .fps(Int(fps))) }.value
          }
        )
        .disabled(playbackOff)
      }

      if let limit = model.frameRateLimit(of: display) {
        HStack(spacing: 8) {
          Text(verbatim: limit.note)
            .font(.system(size: 11.5))
            .foregroundStyle(theme.surface.muted.color)
            .frame(maxWidth: .infinity, alignment: .leading)
          Button(limit.section.openTitle) {
            controller.launch(PanelActionCoordinator.key("openSettings")) {
              try await controller.openSettings(limit.section)
            }
          }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityIdentifier("displays.fps-limit.\(display.id)")
      }

      DisplaysRow(
        item: DisplaysSettingsSection.mute, forced: forced, identity: display.id,
        controlLabel: label(DisplaysSettingsSection.mute.title)
      ) {
        Toggle(
          noLabel,
          isOn: model.binding(
            PanelActionCoordinator.key("displaySetting", id: display.id, detail: "muted"),
            current: display.muted
          ) { muted in try await controller.setDisplay(display.id, .muted(muted)) }
        )
        .toggleStyle(.switch)
        .labelsHidden()
        .disabled(playbackOff)
      }

      DisplaysRow(
        item: DisplaysSettingsSection.volume, forced: forced, identity: display.id,
        controlLabel: label(DisplaysSettingsSection.volume.title)
      ) {
        DisplaysVolumeSlider(
          value: Double(display.volume),
          commit: { volume in
            await controller.launch(
              PanelActionCoordinator.key("displaySetting", id: display.id, detail: "volume")
            ) { try await controller.setDisplay(display.id, .volume(Float(volume))) }.value
          }
        )
        .disabled(playbackOff || display.muted)
      }
    }
  }
}

// MARK: - Copy or swap

struct DisplaysTransferDisclosure: View {
  let display: DisplayRow
  let card: DisplaysCardSearch

  @Environment(PanelController.self) private var controller

  var body: some View {
    let model = controller.displaysSettings
    let peers = controller.transferPeers(of: display.id)
    if !peers.isEmpty {
      let busy = controller.isStoreBusy
      let off = busy || !display.enabled
      let peer = model.peer(of: display.id)
      DisplaysDisclosure(item: DisplaysSettingsSection.transfer, display: display.id, card: card) {
        DisplaysRow(
          item: DisplaysSettingsSection.transferPeer, forced: card.forced, identity: display.id,
          labelsControl: false, stacked: true
        ) {
          HStack(spacing: 8) {
            DisplaysTitleMenu(
              selection: Binding(
                get: { peer?.id ?? "" }, set: { model.peers[display.id] = $0.isEmpty ? nil : $0 }),
              title: peer?.title ?? L("Choose display"), width: 320, alignment: .leading, fitsTitle: true
            ) {
              Text("Choose display").tag("")
              ForEach(peers) { Text(verbatim: $0.title).tag($0.id) }
            }
            .accessibilityLabel(Text(verbatim: L("Destination for \(display.title)")))
            .disabled(off)
            Spacer(minLength: 0)
            Button("Copy wallpaper") {
              guard let peer else { return }
              controller.launch(PanelActionCoordinator.key("displayCopyWallpaper", id: display.id)) {
                await model.copyWallpaper(from: display.id, to: peer.id)
              }
            }
            .accessibilityLabel(
              Text(verbatim: L("Copy wallpaper from \(display.title) to \(peer?.title ?? "")"))
            )
            .disabled(off || peer == nil)
            Button("Swap wallpapers") {
              guard let peer else { return }
              controller.launch(PanelActionCoordinator.key("displaySwapWallpapers", id: display.id)) {
                await model.swapWallpapers(display.id, peer.id)
              }
            }
            .accessibilityLabel(
              Text(
                verbatim: L("Swap wallpapers on \(display.title) and \(peer?.title ?? "")"))
            )
            .disabled(off || peer?.wallpaperID == nil)
          }
        }
        // The result of a copy or swap is reported by the layouts group; it is repeated here, on the
        // display it was started from only, so a failure is not out of sight below the cards.
        if model.transferSource == display.id {
          if let error = model.layoutError {
            DisplaysMessageRow(text: error, isError: true)
          } else if let status = model.layoutStatus {
            DisplaysMessageRow(text: status)
          }
        }
      }
    }
  }
}
