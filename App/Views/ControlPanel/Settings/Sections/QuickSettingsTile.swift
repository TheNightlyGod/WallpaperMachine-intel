import SwiftUI

/// One Quick Settings tile as the page shows it: which setting it switches, whether it is on, and
/// what its state line says in place of On or Off.
///
/// Every tile switches the same preference as the full row of that setting, through the same key, so
/// pressing one moves the other. The rules of which tiles exist and when one cannot be pressed are
/// here, as plain values, and the view only draws them.
struct QuickTile: Identifiable, Equatable {
  let key: SettingsSwitchKey
  /// The glyph in the tile's disc.
  let symbol: String
  let isOn: Bool
  /// False when the setting cannot be changed now, for a reason of its own (a login item outside
  /// Applications, a desktop picture the lock screen owns, a lock screen the Mac cannot offer).
  /// The Mac being busy is not part of it.
  let isEnabled: Bool
  /// Shown beneath the title instead of On or Off: "Unavailable", "Needs approval", the service's
  /// status while it works. Nil while there is nothing to say.
  let note: String?
  /// "Experimental" follows the state line, for the two features that are.
  let isExperimental: Bool

  var id: SettingsSwitchKey { key }

  /// The tiles of the page, in order. Active Display Only is offered only with two displays, or
  /// while it is on so it can be turned off. `isOn` is what each tile shows, drafts included.
  @MainActor
  static func tiles(for controller: PanelController, isOn: (SettingsSwitchKey) -> Bool)
    -> [QuickTile]
  {
    let login = controller.generalSettings.launchAtLogin
    let lock = controller.lockScreenState
    let saver = controller.screenSaverState
    let muted = isOn(.wallpapersMuted)
    var tiles = [
      QuickTile(
        key: .launchAtLogin, symbol: "power", isOn: isOn(.launchAtLogin),
        isEnabled: controller.isSwitchEnabled(.launchAtLogin), note: login.tileNote,
        isExperimental: false),
      QuickTile(
        key: .wallpapersMuted, symbol: muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
        isOn: muted, isEnabled: true, note: nil, isExperimental: false),
      QuickTile(
        key: .lockScreenEnabled, symbol: "lock.fill", isOn: isOn(.lockScreenEnabled),
        isEnabled: controller.isSwitchEnabled(.lockScreenEnabled), note: lock.tileNote,
        isExperimental: true),
      QuickTile(
        key: .screenSaverEnabled, symbol: "play.display", isOn: isOn(.screenSaverEnabled),
        isEnabled: controller.isSwitchEnabled(.screenSaverEnabled), note: saver.tileNote,
        isExperimental: true),
      QuickTile(
        key: .writeDesktopPicture, symbol: "desktopcomputer", isOn: isOn(.writeDesktopPicture),
        isEnabled: controller.isSwitchEnabled(.writeDesktopPicture), note: nil, isExperimental: false),
      desktopWallpapersTile(for: controller, isOn: isOn(.desktopWallpapers)),
    ]
    if controller.playbackSettings.showsActiveDisplayOnly {
      tiles.append(
        QuickTile(
          key: .playOnlyOnActiveDisplay, symbol: "cursorarrow",
          isOn: isOn(.playOnlyOnActiveDisplay), isEnabled: true, note: nil, isExperimental: false))
    }
    tiles += [
      QuickTile(
        key: .hideAfterActivating, symbol: "macwindow", isOn: isOn(.hideAfterActivating),
        isEnabled: true, note: nil, isExperimental: false),
      QuickTile(
        key: .livePropertyEdits, symbol: "eye.fill", isOn: isOn(.livePropertyEdits),
        isEnabled: true, note: nil, isExperimental: false),
    ]
    return tiles
  }

  /// Wallpaper per Desktop, for the display the Library applies wallpapers to. With several displays
  /// its state line names that display; one that cannot have it says Unavailable.
  @MainActor
  private static func desktopWallpapersTile(for controller: PanelController, isOn: Bool) -> QuickTile {
    let enabled = controller.isSwitchEnabled(.desktopWallpapers)
    let displays = controller.targetDisplays
    var note: String?
    if !enabled {
      note = L("Unavailable")
    } else if displays.filter(\.isSelectable).count > 1, let target = controller.targetDisplay {
      note = "\(isOn ? L("On") : L("Off")) · \(target.shortLabel(among: displays))"
    }
    return QuickTile(
      key: .desktopWallpapers, symbol: "rectangle.3.group", isOn: isOn, isEnabled: enabled, note: note,
      isExperimental: false)
  }

  /// The state itself: the note when there is one, else On or Off.
  @MainActor var state: String { note ?? (isOn ? L("On") : L("Off")) }

  /// The state line: the state, then "· Experimental" where it applies.
  @MainActor var stateLine: String {
    isExperimental ? "\(state) · \(L("Experimental"))" : state
  }
}

/// A Control Center style tile: a disc with the glyph, the setting's name and its state. The disc
/// takes the accent while the setting is on.
struct QuickTileView: View {
  let tile: QuickTile
  let title: String
  /// The Mac is busy, so the tile waits.
  let isLocked: Bool
  let action: () -> Void

  @Environment(\.panelTheme) private var theme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        Image(systemName: tile.symbol)
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(tile.isOn ? theme.accent.onPrimary.color : theme.surface.text.color)
          .frame(width: 32, height: 32)
          .background(
            Circle().fill(tile.isOn ? theme.accent.primary.color : theme.surface.badge.color)
          )
        VStack(alignment: .leading, spacing: 1) {
          // A long name ("Wallpaper per Desktop" on the narrowest tile) shrinks a little before
          // it truncates.
          Text(verbatim: title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(theme.surface.text.color)
            .lineLimit(1)
            .allowsTightening(true)
            .minimumScaleFactor(0.8)
          // The whole line when it fits; the state alone when the tile is too narrow for the badge.
          ViewThatFits(in: .horizontal) {
            stateText(tile.stateLine)
            stateText(tile.state)
          }
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
      .background(
        theme.surface.card.color, in: RoundedRectangle(cornerRadius: 12, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .strokeBorder(theme.surface.divider.color, lineWidth: 0.5)
      }
      .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    .buttonStyle(QuickTilePressStyle(reduceMotion: reduceMotion))
    .disabled(!tile.isEnabled || isLocked)
    .opacity(tile.isEnabled ? 1 : 0.5)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text(verbatim: title))
    .accessibilityValue(Text(verbatim: tile.stateLine))
    .accessibilityAddTraits(.isToggle)
    .accessibilityIdentifier("quick.tile.\(tile.key.rawValue)")
  }
}

extension QuickTileView {
  private func stateText(_ text: String) -> some View {
    Text(verbatim: text)
      .font(.system(size: 11.5))
      .foregroundStyle(tile.isOn ? theme.accent.accent.color : theme.surface.muted.color)
      .lineLimit(1)
  }
}

/// Shrinks the tile a little while it is pressed.
private struct QuickTilePressStyle: ButtonStyle {
  let reduceMotion: Bool

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
  }
}
