import SwiftUI

/// The bar along the bottom of the window: what the target display is showing, and the previous,
/// play or pause, next, playlist and Recently used buttons. While the target display rotates, the
/// line under the title names what it rotates through and the playlist button is lit.
///
/// The wallpaper's part of the bar is a button: it lights on hover and opens the details, a wider
/// still with the title, its kind, the display and the playback state, and Show in library.
///
/// Play and pause act on every display, so the status reports them even when the target display is
/// empty and the button works while any display has a wallpaper. Previous and next act on the target
/// display only. The equalizer moves only while the wallpaper plays and the window is on screen.
///
/// While a season is on, the bar is the ground its horizon (`SeasonHorizon`) rises from: the
/// horizon's ink in either appearance, its contents in the season's dark palette. What it opens over
/// the window keeps the window's own palette (`panelWindowLook`).
struct NowPlayingBar: View {
  /// The bar's height, which the pages above it give up.
  static let height: CGFloat = 52

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let ground = theme.season.map { PanelTheme(season: $0, appearance: .dark) }
    bar
      .background(ground == nil ? theme.surface.surface.color : SeasonHorizon.ink.color)
      .overlay(alignment: .top) {
        if ground == nil {
          Rectangle().fill(theme.surface.line.color).frame(height: 0.5)
        }
      }
      .environment(\.panelTheme, ground ?? theme)
      .environment(\.panelWindowTheme, theme)
      .tint((ground ?? theme).accent.accent.color)
      .accessibilityElement(children: .contain)
      .accessibilityLabel(Text(verbatim: controller.nowPlaying.accessibilityLabel))
      .accessibilityValue(Text(verbatim: controller.nowPlaying.status))
      .accessibilityIdentifier("now-playing")
  }

  private var bar: some View {
    let shell = controller.shell
    let state = controller.nowPlaying
    return HStack(spacing: 12) {
      NowPlayingSummary(state: state)
        .frame(maxWidth: 420, alignment: .leading)
      Spacer(minLength: 8)
      HStack(spacing: 2) {
        NowPlayingControl(
          systemImage: "backward.fill", label: L("Previous wallpaper"),
          isEnabled: state.canGoPrevious && !shell.isPreviousBusy,
          identifier: "now-playing-previous"
        ) { shell.previousWallpaper() }
        NowPlayingControl(
          systemImage: state.showsPlay ? "play.fill" : "pause.fill", label: state.playbackLabel,
          isEnabled: state.canTogglePlayback && !shell.isPlaybackBusy, isProminent: true,
          identifier: "now-playing-toggle"
        ) { shell.togglePlayback() }
        NowPlayingControl(
          systemImage: "forward.fill", label: L("Next wallpaper"),
          isEnabled: state.canGoNext && !shell.isNextBusy, identifier: "now-playing-next"
        ) { shell.nextWallpaper() }
        NowPlayingPlaylistButton()
        history(shell)
      }
      .frame(width: 200)
    }
    .padding(.horizontal, 10)
    .frame(height: Self.height)
    .frame(maxWidth: .infinity)
  }

  /// Recently used: opens the target display's history in a popover above the bar.
  private func history(_ shell: ShellModel) -> some View {
    NowPlayingControl(
      systemImage: "clock.arrow.circlepath", label: L("Recently used"),
      identifier: "now-playing-history"
    ) {
      let isOpen = shell.activePopover == .history
      shell.popover(.history).wrappedValue = !isOpen
    }
    // Upward: the bar is at the bottom of the window, so one below would be pushed back up by the
    // screen edge.
    .popover(isPresented: shell.popover(.history), arrowEdge: .top) {
      RecentlyUsedPopover().panelPresentationLocale().panelWindowLook()
    }
  }
}

/// The wallpaper's part of the bar: its still, its title, and under it the display and the
/// equalizer, or what to do when nothing plays. A click opens the details above it.
private struct NowPlayingSummary: View {
  let state: NowPlayingState

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let shell = controller.shell
    Button {
      let isOpen = shell.activePopover == .nowPlaying
      shell.popover(.nowPlaying).wrappedValue = !isOpen
    } label: {
      HStack(spacing: 10) {
        NowPlayingCover(source: state.item?.still, width: 36, height: 36, cornerRadius: 7)
        VStack(alignment: .leading, spacing: 1) {
          Text(verbatim: state.title)
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(theme.surface.text.color)
            .lineLimit(1)
            .truncationMode(.tail)
          HStack(spacing: 5) {
            if state.item != nil {
              Equalizer(isPlaying: state.isEqualizerRunning, barWidth: 2, height: 9)
                .foregroundStyle(theme.accent.accent.color)
                .opacity(state.isEqualizerRunning ? 1 : 0.45)
            }
            Text(verbatim: state.item == nil ? state.detail : displayName(state))
              .font(.system(size: 11))
              .foregroundStyle(theme.surface.muted.color)
              .lineLimit(1)
              .truncationMode(.tail)
          }
        }
        Image(systemName: "chevron.up")
          .font(.system(size: 9, weight: .bold))
          .foregroundStyle(theme.surface.faint.color)
          .accessibilityHidden(true)
      }
    }
    .buttonStyle(NowPlayingSummaryStyle())
    .help(state.help)
    .accessibilityLabel(Text(verbatim: state.title))
    .accessibilityValue(Text(verbatim: state.item == nil ? state.detail : state.status))
    .accessibilityHint(Text("Details"))
    .accessibilityIdentifier("now-playing-details")
    .popover(isPresented: shell.popover(.nowPlaying), arrowEdge: .top) {
      NowPlayingDetails().panelPresentationLocale().panelWindowLook()
    }
  }

  /// The target display as the toolbar's menu button names it, which is what the line has room
  /// for, and what it rotates through; the details and VoiceOver keep the full title.
  private func displayName(_ state: NowPlayingState) -> String {
    let displays = controller.targetDisplays
    let target = displays.first { $0.id == controller.targetDisplayID }
    let name = target?.shortLabel(among: displays) ?? state.displayTitle
    guard let rotation = NowPlayingRotation(controller: controller) else { return name }
    return "\(name) · \(rotation.title)"
  }
}

extension EnvironmentValues {
  /// The window's palettes inside a part that wears others (the Now Playing bar in a season), for
  /// what that part opens over the window. Nil elsewhere.
  @Entry var panelWindowTheme: PanelTheme?
}

extension View {
  /// Gives a popover opened from a part with palettes of its own the window's palettes back.
  fileprivate func panelWindowLook() -> some View {
    modifier(PanelWindowLook())
  }
}

private struct PanelWindowLook: ViewModifier {
  @Environment(\.panelWindowTheme) private var window

  func body(content: Content) -> some View {
    if let window {
      content.environment(\.panelTheme, window).tint(window.accent.accent.color)
    } else {
      content
    }
  }
}

/// The summary's look: a rounded area that fills on hover and press, so it reads as something to
/// click.
private struct NowPlayingSummaryStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    NowPlayingSummaryBody(configuration: configuration)
  }
}

private struct NowPlayingSummaryBody: View {
  let configuration: ButtonStyleConfiguration

  @Environment(\.panelTheme) private var theme
  @State private var isHovering = false

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
    configuration.label
      .padding(.horizontal, 6)
      .padding(.vertical, 4)
      .background(fill, in: shape)
      .contentShape(shape)
      .onHover { isHovering = $0 }
  }

  private var fill: Color {
    if configuration.isPressed { return theme.surface.pressed.color }
    return isHovering ? theme.surface.hover.color : .clear
  }
}

/// The details the bar opens: the wallpaper's still at a size that shows it, its title and kind, the
/// display and the playback state, and Show in library. With nothing on the target display it says
/// what to do instead.
struct NowPlayingDetails: View {
  static let width: CGFloat = 320

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let state = controller.nowPlaying
    let coverWidth = Self.width - 32
    VStack(alignment: .leading, spacing: 12) {
      if let item = state.item {
        NowPlayingCover(
          source: item.still, width: coverWidth, height: (coverWidth * 9 / 16).rounded(),
          cornerRadius: 10)
      }
      VStack(alignment: .leading, spacing: 3) {
        Text("Now Playing")
          .font(.system(size: 10, weight: .semibold))
          .textCase(.uppercase)
          .tracking(0.4)
          .foregroundStyle(theme.surface.muted.color)
        Text(verbatim: state.title)
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(theme.surface.text.color)
          .lineLimit(3)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
        if let item = state.item {
          Text(verbatim: item.kind.label)
            .font(.system(size: 12))
            .foregroundStyle(theme.surface.muted.color)
        }
      }
      VStack(alignment: .leading, spacing: 6) {
        if !state.displayTitle.isEmpty {
          Label {
            Text(verbatim: state.displayTitle).lineLimit(2)
          } icon: {
            Image(systemName: "display")
          }
        }
        Label {
          Text(verbatim: state.item == nil ? state.detail : state.status)
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
          if state.item != nil {
            Equalizer(isPlaying: state.isEqualizerRunning, barWidth: 2, height: 10)
              .foregroundStyle(theme.accent.accent.color)
              .opacity(state.isEqualizerRunning ? 1 : 0.45)
          } else {
            Image(systemName: "pause.circle")
          }
        }
      }
      .font(.system(size: 12))
      .foregroundStyle(theme.surface.text.color)
      if let item = state.item {
        Button("Show in library") {
          controller.shell.popover(.nowPlaying).wrappedValue = false
          controller.shell.showInstalled(item.id)
        }
        .buttonStyle(.panelSecondary)
        .disabled(controller.isBusy(PanelActionCoordinator.key("showInstalled", id: item.id)))
        .help(state.showInLibraryLabel ?? "")
        .accessibilityLabel(Text(verbatim: state.showInLibraryLabel ?? L("Show in library")))
        .accessibilityIdentifier("now-playing-show-in-library")
      }
    }
    .padding(16)
    .frame(width: Self.width, alignment: .leading)
    .accessibilityIdentifier("now-playing-popover")
  }
}
