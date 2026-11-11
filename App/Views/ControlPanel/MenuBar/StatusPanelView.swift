import SwiftUI

/// The popover's root: the panel in the app's theme and the panel's live language, over the
/// controller of this opening and its image pipeline.
struct StatusPanelRoot: View {
  let controller: StatusPanelController

  var body: some View {
    StatusPanelView()
      .environment(controller)
      .environment(\.panelImages, controller.images)
      .panelTheme(theme: .shared, locale: .shared)
  }
}

/// The panel a click on the menu bar icon opens: the chosen display's wallpaper with its state,
/// favorite heart and transport, its own volume, a quick switcher of eight wallpapers, the ones
/// used there recently, and the way to the control panel, Settings and Quit.
///
/// It only draws and starts `StatusPanelController`'s typed actions. Covers come from the image
/// pipeline once their stamps are read, never a full-size preview or a live render, and nothing in
/// it moves on its own.
struct StatusPanelView: View {
  static let width: CGFloat = 320

  @Environment(StatusPanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let panel = controller.panel
    VStack(alignment: .leading, spacing: 14) {
      if panel.showsDisplayPicker {
        SettingsSegmentedControl(
          segments: panel.displays.map { .init(value: $0.id, title: $0.shortTitle) },
          selection: panel.displayID
        ) { controller.chooseDisplay($0) }
        .accessibilityLabel(Text("Display"))
        .accessibilityIdentifier("status-panel-displays")
      }
      if panel.state == .unavailable {
        Text("WallpaperMachine is still starting, or its renderer could not start. Try again in a moment.")
          .font(.system(size: 12))
          .foregroundStyle(theme.surface.muted.color)
          .fixedSize(horizontal: false, vertical: true)
      } else {
        StatusPanelNowPlaying()
        StatusPanelTransport()
        if panel.wallpaper != nil { StatusPanelSound() }
        StatusPanelSwitcher()
        if !panel.recent.isEmpty { StatusPanelRecent() }
      }
      if let update = panel.update {
        Button { controller.openUpdates() } label: {
          Label {
            Text(verbatim: update.title)
              .font(.system(size: 12, weight: .medium))
              .fixedSize(horizontal: false, vertical: true)
          } icon: { Image(systemName: "arrow.down.circle") }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.accent.accent.color)
        .accessibilityIdentifier("status-panel-update")
      }
      Divider()
      StatusPanelFooter()
      if let failure = controller.failure {
        Text(verbatim: failure)
          .font(.system(size: 11.5))
          .foregroundStyle(theme.surface.danger.color)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
      }
    }
    .padding(16)
    .frame(width: Self.width, alignment: .leading)
    .announcesChanges(of: controller.failure)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("status-panel")
  }
}

/// A section's caption, as the Now Playing details caption theirs.
private struct StatusPanelCaption: View {
  let text: Text

  @Environment(\.panelTheme) private var theme

  var body: some View {
    text
      .font(.system(size: 10, weight: .semibold))
      .textCase(.uppercase)
      .tracking(0.4)
      .foregroundStyle(theme.surface.muted.color)
      .accessibilityAddTraits(.isHeader)
  }
}

/// The wallpaper at 16:9, its title and state, and the heart.
private struct StatusPanelNowPlaying: View {
  @Environment(StatusPanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let panel = controller.panel
    let width = StatusPanelView.width - 32
    VStack(alignment: .leading, spacing: 10) {
      NowPlayingCover(
        source: panel.wallpaper.flatMap(controller.cover(for:)), width: width,
        height: (width * 9 / 16).rounded(), cornerRadius: 10)
      // Clipping an aspect-filled image leaves its hit area outside the visible cover.
      // This cover is decorative, so it must not intercept the display picker above it.
      .allowsHitTesting(false)
      HStack(alignment: .top, spacing: 8) {
        VStack(alignment: .leading, spacing: 3) {
          Text(verbatim: panel.wallpaper?.title ?? L("Nothing on this display"))
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(theme.surface.text.color)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
          Text(verbatim: panel.stateLine)
            .font(.system(size: 11.5))
            .foregroundStyle(theme.surface.muted.color)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        if panel.wallpaper != nil {
          NowPlayingControl(
            systemImage: panel.isFavorite ? "heart.fill" : "heart",
            label: panel.isFavorite ? L("Remove from favorites") : L("Add to favorites"),
            isEnabled: !controller.isBusy(controller.key("favorite")),
            tint: panel.isFavorite ? theme.surface.heart.color : nil, identifier: "status-panel-favorite"
          ) {
            controller.launch(controller.key("favorite")) { try await controller.toggleFavorite() }
          }
          .frame(width: 32)
          .accessibilityAddTraits(panel.isFavorite ? .isSelected : [])
        }
      }
    }
  }
}

/// Previous, play or pause, next and a random wallpaper: the menu's commands for the display.
private struct StatusPanelTransport: View {
  @Environment(StatusPanelController.self) private var controller

  var body: some View {
    let panel = controller.panel
    HStack(spacing: 4) {
      NowPlayingControl(
        systemImage: "backward.fill", label: L("Previous wallpaper"),
        isEnabled: panel.canPrevious && !busy("previous"), identifier: "status-panel-previous"
      ) {
        controller.launch(controller.key("previous")) { try await controller.previous() }
      }
      NowPlayingControl(
        systemImage: panel.isPaused || !panel.canTogglePlayback ? "play.fill" : "pause.fill",
        label: !panel.canTogglePlayback
          ? L("No wallpaper playing")
          : panel.isPaused ? L("Resume wallpaper playback") : L("Pause wallpaper playback"),
        isEnabled: panel.canTogglePlayback && !busy("playback"), isProminent: true,
        identifier: "status-panel-toggle"
      ) {
        controller.launch(controller.key("playback")) { try await controller.togglePlayback() }
      }
      NowPlayingControl(
        systemImage: "forward.fill", label: L("Next wallpaper"),
        isEnabled: panel.canNext && !busy("next"), identifier: "status-panel-next"
      ) {
        controller.launch(controller.key("next")) { try await controller.next() }
      }
      NowPlayingControl(
        systemImage: "shuffle", label: L("Random wallpaper"),
        isEnabled: panel.canRandom && !busy("random"), identifier: "status-panel-random"
      ) {
        controller.launch(controller.key("random")) { try await controller.randomWallpaper() }
      }
    }
  }

  private func busy(_ action: String) -> Bool { controller.isBusy(controller.key(action)) }
}

/// The wallpaper's own mute and volume, as the inspector sets them. While Mute All is on neither
/// can change anything, so both are locked and the note offers to turn it off.
private struct StatusPanelSound: View {
  @Environment(StatusPanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let panel = controller.panel
    let volume = controller.volume
    let ownMute = volume?.muted ?? false
    let silent = panel.wallpapersMuted || ownMute
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .bottom, spacing: 8) {
        NowPlayingControl(
          systemImage: silent ? "speaker.slash.fill" : "speaker.wave.2.fill",
          label: ownMute ? L("Unmute") : L("Mute this wallpaper"),
          isEnabled: volume != nil && !panel.wallpapersMuted && !busy("mute"),
          identifier: "status-panel-mute"
        ) {
          controller.launch(controller.key("mute"), policy: .latestWins) {
            try await controller.setMuted(!ownMute)
          }
        }
        .frame(width: 32)
        DraggableSlider(
          value: (volume?.volume ?? 0) * 100, range: 0...100, step: 1,
          format: { InspectorWording.percent($0 / 100) }, accessibilityLabel: L("Volume"),
          onRelease: { setVolume($0 / 100) }, onStep: { setVolume($0 / 100) }
        ) { output in
          HStack(spacing: 8) {
            Text("Volume")
              .font(.system(size: 12))
              .foregroundStyle(theme.surface.text.color)
              .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: volume == nil ? "" : output)
              .font(.system(size: 11.5).monospacedDigit())
              .foregroundStyle(theme.surface.muted.color)
              .accessibilityHidden(true)
          }
        }
        .disabled(volume == nil || silent)
      }
      if panel.wallpapersMuted {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text("Mute All is on, so every wallpaper is silent.")
            .font(.system(size: 11.5))
            .foregroundStyle(theme.surface.muted.color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
          Button("Unmute Wallpapers") {
            controller.launch(controller.key("unmuteAll")) { try await controller.unmuteAll() }
          }
          .buttonStyle(DiscoverSecondaryButtonStyle(size: .small))
          .disabled(busy("unmuteAll"))
        }
      }
    }
  }

  private func busy(_ action: String) -> Bool { controller.isBusy(controller.key(action)) }

  private func setVolume(_ fraction: Double) -> Task<Void, Never> {
    controller.launch(controller.key("volume"), policy: .latestWins) {
      try await controller.setVolume(fraction)
    }
  }
}

/// Eight wallpapers to change to in one click, from the favorites or the whole library, and a
/// button that draws eight others.
private struct StatusPanelSwitcher: View {
  @Environment(StatusPanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)

  var body: some View {
    let panel = controller.panel
    if panel.isLibraryEmpty {
      Text("Your wallpaper library is empty")
        .font(.system(size: 12))
        .foregroundStyle(theme.surface.muted.color)
    } else if !panel.strip.isEmpty {
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 6) {
          if panel.stripSource == .favorites {
            StatusPanelCaption(text: Text("Favorites"))
          } else {
            StatusPanelCaption(text: Text("All wallpapers"))
          }
          Spacer(minLength: 4)
          Button {
            controller.showOtherWallpapers()
          } label: {
            Image(systemName: "arrow.triangle.2.circlepath")
              .font(.system(size: 11, weight: .semibold))
              .foregroundStyle(theme.surface.muted.color)
          }
          .buttonStyle(.plain)
          .disabled(!panel.canShowOthers)
          .help(L("Show other wallpapers"))
          .accessibilityLabel(Text("Show other wallpapers"))
          .accessibilityIdentifier("status-panel-shuffle")
        }
        LazyVGrid(columns: columns, spacing: 6) {
          ForEach(panel.strip) { wallpaper in
            StatusPanelThumbnail(wallpaper: wallpaper, isShown: wallpaper.id == panel.wallpaper?.id)
          }
        }
      }
    }
  }
}

/// One wallpaper of the quick switcher: its cover, lit on hover and ringed while the display shows
/// it. A click applies it to the display.
private struct StatusPanelThumbnail: View {
  let wallpaper: StatusPanelModel.Wallpaper
  let isShown: Bool

  @Environment(StatusPanelController.self) private var controller
  @Environment(\.panelTheme) private var theme
  @State private var isHovering = false

  var body: some View {
    let key = controller.key("apply", id: wallpaper.id)
    let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
    Button {
      controller.launch(key) { try await controller.apply(wallpaper.id) }
    } label: {
      ZStack {
        theme.surface.mediaWell.color
        PanelImage(source: controller.cover(for: wallpaper), pointSize: 72, contentMode: .fill)
      }
      .aspectRatio(16 / 10, contentMode: .fit)
      .clipShape(shape)
      .overlay {
        shape.strokeBorder(
          isShown ? theme.accent.accent.color : isHovering ? theme.surface.line.color : theme.surface.divider.color,
          lineWidth: isShown ? 2 : isHovering ? 1 : 0.5)
      }
      .contentShape(shape)
    }
    .buttonStyle(.plain)
    .disabled(controller.isBusy(key))
    .onHover { isHovering = $0 }
    .help(wallpaper.title)
    .accessibilityLabel(Text(verbatim: wallpaper.title))
    .accessibilityAddTraits(isShown ? .isSelected : [])
  }
}

/// Wallpapers used on the display before, newest first; a click applies one again.
private struct StatusPanelRecent: View {
  @Environment(StatusPanelController.self) private var controller

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      StatusPanelCaption(text: Text("Recently used"))
      ForEach(controller.panel.recent) { wallpaper in
        StatusPanelRecentRow(wallpaper: wallpaper)
      }
    }
  }
}

private struct StatusPanelRecentRow: View {
  let wallpaper: StatusPanelModel.Wallpaper

  @Environment(StatusPanelController.self) private var controller
  @Environment(\.panelTheme) private var theme
  @State private var isHovering = false

  var body: some View {
    let key = controller.key("apply", id: wallpaper.id)
    Button {
      controller.launch(key) { try await controller.apply(wallpaper.id) }
    } label: {
      HStack(spacing: 8) {
        NowPlayingCover(source: controller.cover(for: wallpaper), width: 34, height: 22, cornerRadius: 4)
        Text(verbatim: wallpaper.title)
          .font(.system(size: 12))
          .foregroundStyle(theme.surface.text.color)
          .lineLimit(1)
          .truncationMode(.tail)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 4)
      .padding(.vertical, 2)
      .background(
        isHovering ? theme.surface.selected.color : .clear,
        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(controller.isBusy(key))
    .onHover { isHovering = $0 }
    .accessibilityLabel(Text(verbatim: wallpaper.title))
  }
}

/// The control panel, Settings and Quit. Each closes the panel before it acts.
private struct StatusPanelFooter: View {
  @Environment(StatusPanelController.self) private var controller

  var body: some View {
    HStack(spacing: 6) {
      Button {
        controller.openControlPanel()
      } label: {
        Label("Control Panel", systemImage: "macwindow")
      }
      .accessibilityIdentifier("status-panel-control-panel")
      Button {
        controller.openSettings()
      } label: {
        Label("Settings", systemImage: "gearshape")
      }
      .accessibilityIdentifier("status-panel-settings")
      Spacer(minLength: 4)
      Button {
        controller.quit()
      } label: {
        Image(systemName: "power")
      }
      .help(L("Quit WallpaperMachine"))
      .accessibilityLabel(Text("Quit WallpaperMachine"))
      .accessibilityIdentifier("status-panel-quit")
    }
    .buttonStyle(ToolbarCapsuleButtonStyle())
  }
}

extension StatusPanelModel.Panel {
  /// The line under the title: the wallpaper's kind and what holds it, or what to do with an empty
  /// display.
  @MainActor var stateLine: String {
    let status: String =
      switch state {
      case .unavailable: L("Starting…")
      case .switching: L("Changing wallpaper…")
      case .empty:
        strip.isEmpty
          ? L("Pick a wallpaper and press Play to show it here.")
          : L("Choose a wallpaper below to show it here.")
      case .paused: L("Playback paused")
      case .held(let hold): hold.text
      case .playing: L("Playback running")
      }
    guard let wallpaper, state != .empty else { return status }
    return "\(wallpaper.kind.label) · \(status)"
  }
}

extension StatusPanelModel.Hold {
  /// The rule's own words where it has them (Playback & Power's), and what holds wallpapers otherwise.
  @MainActor var text: String {
    switch self {
    case .libraryDrive: L("The wallpaper library’s drive is disconnected. Wallpapers are stopped.")
    case .condition(let condition): condition.statusText
    case .onBattery: L("On battery. Wallpapers are paused.")
    case .rule(stopped: false): L("A playback rule is in effect. Wallpapers are paused.")
    case .rule(stopped: true): L("A playback rule is in effect. Wallpapers are stopped.")
    }
  }
}
