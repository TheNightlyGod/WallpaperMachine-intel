import SwiftUI

/// Now Playing's playlist button: lit while the target display rotates, with the order's symbol,
/// and named after what it rotates through. It opens the playlist's state above the bar.
struct NowPlayingPlaylistButton: View {
  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let shell = controller.shell
    let rotation = NowPlayingRotation(controller: controller)
    NowPlayingControl(
      systemImage: rotation?.state.playlist.order == .shuffle ? "shuffle" : "repeat",
      label: rotation.map { L("Playlist: \($0.title)") } ?? L("Playlist"),
      isEnabled: controller.targetDisplay?.isSelectable == true,
      tint: rotation == nil ? nil : theme.accent.accent.color,
      identifier: "now-playing-playlist"
    ) {
      let isOpen = shell.activePopover == .playlist
      shell.popover(.playlist).wrappedValue = !isOpen
    }
    .popover(isPresented: shell.popover(.playlist), arrowEdge: .top) {
      NowPlayingPlaylistDetails().panelPresentationLocale()
    }
  }
}

/// The target display's rotation as Now Playing names it; nil while that display does not rotate.
struct NowPlayingRotation {
  let state: PlaylistState
  /// What it rotates through: All wallpapers, Favorites, the display's list or a collection's name.
  let title: String

  @MainActor init?(controller: PanelController) {
    guard controller.targetDisplay?.isSelectable == true else { return nil }
    let state = controller.playlistState(for: controller.targetDisplayID)
    guard state.playlist.mode == .rotate else { return nil }
    self.state = state
    title = state.sourceTitle(collections: controller.collectionRows)
  }
}

/// The playlist above the bar: what the target display rotates through, its order and interval,
/// when it changes next, and Change now, Stop and Settings…. A display that does not rotate says how
/// to start one.
private struct NowPlayingPlaylistDetails: View {
  static let width: CGFloat = 300

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let display = controller.targetDisplayID
    let state = controller.playlistState(for: display)
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        Text("Playlist")
          .font(.system(size: 10, weight: .semibold))
          .textCase(.uppercase)
          .tracking(0.4)
          .foregroundStyle(theme.surface.muted.color)
        Text(verbatim: title(state))
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(theme.surface.text.color)
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
        if state.playlist.mode == .rotate {
          let order = state.playlist.order == .shuffle ? L("Shuffle") : L("In order")
          Text(verbatim: "\(order) · \(state.interval.title)")
            .font(.system(size: 12))
            .foregroundStyle(theme.surface.muted.color)
        }
      }
      Text(verbatim: note(state))
        .font(.system(size: 12))
        .foregroundStyle(theme.surface.text.color)
        .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 8) {
        if state.showsResume {
          Button("Resume playlist") {
            controller.launch(PanelActionCoordinator.key("playlistResume", id: display)) {
              try await controller.resumePlaylist(display: display)
            }
          }
          .accessibilityIdentifier("now-playing-playlist-resume")
        } else if state.playlist.mode == .rotate {
          Button("Change now") {
            controller.launch(PanelActionCoordinator.key("playlistSkip", id: display)) {
              try await controller.skipPlaylist(display: display)
            }
          }
          .accessibilityIdentifier("now-playing-playlist-skip")
        }
        if state.playlist.mode != .off {
          Button("Stop") {
            controller.launch(PanelActionCoordinator.key("playlistStop", id: display)) {
              try await controller.editPlaylist(.mode(.off), display: display)
            }
          }
          .help(L("The wallpaper on screen stays until you change it."))
          .accessibilityIdentifier("now-playing-playlist-stop")
        }
        Spacer(minLength: 0)
        Button("Settings…") {
          controller.shell.popover(.playlist).wrappedValue = false
          controller.launch(PanelActionCoordinator.key("openSettings")) {
            try await controller.openSettings(.displays)
          }
        }
        .accessibilityIdentifier("now-playing-playlist-settings")
      }
      .buttonStyle(.panelSecondary)
    }
    .padding(16)
    .frame(width: Self.width, alignment: .leading)
    .accessibilityIdentifier("now-playing-playlist-popover")
  }

  private func title(_ state: PlaylistState) -> String {
    switch state.playlist.mode {
    case .rotate: state.sourceTitle(collections: controller.collectionRows)
    case .dayNight: L("Day and night")
    case .off: L("Off")
    }
  }

  private func note(_ state: PlaylistState) -> String {
    switch state.playlist.mode {
    case .rotate: state.showsResume ? L("Playlist paused") : state.nextNote
    case .dayNight: state.showsResume ? L("Playlist paused") : L("Changes between the day and night wallpapers.")
    case .off:
      L("To rotate wallpapers, press Play above All wallpapers, Favorites or a collection in Installed.")
    }
  }
}
