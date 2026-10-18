import SwiftUI

/// The ring a pixiv tile wears over its picture while a page of the work is on its way: progress
/// while it transfers, a click to cancel, a play mark when it is paused, a retry mark after a
/// failure. The state and the words come from `TileDownloadState`; this only draws them.
///
/// The disc is dark whatever the appearance, since it sits over artwork. Only a ring that has no
/// measured progress moves, and only while the panel is on screen (`ProgressRing`).
struct PixivTileRing: View {
  let state: TileDownloadState
  let action: () -> Void

  @Environment(\.panelTheme) private var theme
  @Environment(\.isFocused) private var isFocused
  @State private var isHovering = false

  static let maximumSide: CGFloat = 52

  var body: some View {
    Button(action: action) {
      ZStack {
        Circle().fill(.black.opacity(isHovering ? 0.72 : 0.58))
        ProgressRing(value: arc, lineWidth: 3)
          .padding(3)
          .tint(tint)
        center
      }
      .environment(\.colorScheme, .dark)
      .aspectRatio(1, contentMode: .fit)
      .frame(maxWidth: Self.maximumSide, maxHeight: Self.maximumSide)
      .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    .help(state.label)
    .accessibilityLabel(state.label)
    .accessibilityIdentifier("pixiv-tile-ring")
    .padding(8)
  }

  /// A paused or waiting page draws no arc, only the track; a failed one draws a full ring.
  private var arc: Double? {
    switch state.kind {
    case .progress: state.progress ?? 0
    case .busy: nil
    case .queued, .attention: 0
    case .failed: 1
    }
  }

  private var tint: Color {
    state.kind == .failed ? theme.surface.danger.color : theme.accent.base.color
  }

  private var showsClose: Bool { state.showsCloseOnHover && (isHovering || isFocused) }

  @ViewBuilder
  private var center: some View {
    if showsClose {
      Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
    } else if let glyph = state.glyph {
      Image(systemName: Self.symbol(for: glyph))
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(state.kind == .queued ? .white.opacity(0.78) : .white)
    } else if !state.text.isEmpty {
      Text(verbatim: state.text)
        .font(.system(size: state.isStepWord ? 9 : 11.5, weight: .semibold).monospacedDigit())
        .foregroundStyle(.white)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .padding(.horizontal, 6)
    }
  }

  static func symbol(for glyph: TileDownloadState.Glyph) -> String {
    switch glyph {
    case .play: "play.fill"
    case .shield: "exclamationmark.shield.fill"
    case .download: "arrow.down"
    case .refresh: "arrow.clockwise"
    }
  }
}
