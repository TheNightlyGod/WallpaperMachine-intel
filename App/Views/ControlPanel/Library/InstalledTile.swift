import AppKit
import SwiftUI

/// One wallpaper of the Installed grid: its cover, its title and type, the marks it wears, the
/// controls that appear over it, and what a click on it does.
///
/// The tile draws state it reads itself (the ticked and chosen state, the Active pill, the apply
/// ring), so a tick or a download tick re-renders the tiles on screen and never rebuilds the rows
/// they come from.
struct InstalledTile: View {
  let row: LibraryRow
  /// The wallpapers other displays show, which the page works out once for every tile.
  let otherDisplayIDs: Set<String>

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme
  @Environment(\.isFocused) private var isFocused
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
  @Environment(\.accessibilitySwitchControlEnabled) private var switchControlEnabled
  @State private var isHovering = false

  /// Whether the check and the heart stay in the tile while they are hidden, so VoiceOver and
  /// Switch Control can always reach them. Otherwise they are built only while they show: two
  /// hidden buttons in every tile were most of what a new row cost to build, and scrolling builds
  /// a row at every step, so they made the grid drop frames.
  private var keepsHiddenControls: Bool { voiceOverEnabled || switchControlEnabled }

  var body: some View {
    let model = controller.library
    let isChecked = model.isChecked(row.id)
    let isChosen = controller.selectedWallpaperID == row.id
    let isFavorite = controller.favoriteIDs.contains(row.id)
    let isArming = model.armingID == row.id
    let marks = LibraryTileMarks(row, isFavorite: isFavorite)
    let chrome = LibraryTileChrome(
      isChecked: isChecked, isChosen: isChosen, isFavorite: isFavorite, isHovering: isHovering,
      isFocused: isFocused, isArming: isArming, isSelecting: model.isSelecting,
      hasSelection: !model.selection.isEmpty)
    let kind = row.kind.label
    // The tile reads as selected only while the inspector shows it, as the web panel's tile did;
    // ticked is its check's own state.
    WallpaperTile(title: row.title, subtitle: kind, kind: kind, isSelected: isChosen) {
      artwork(model)
    }
    .emphasis(chrome.emphasis)
    .topLeadingBadge {
      // The pill and the check each hang alone from the corner. In a stack beside the check,
      // `ViewThatFits` settles on its narrowest choice whatever the room, which is how the word
      // "Active" went missing; alone in an overlay it is offered the tile's width and picks the
      // word whenever it fits. The pill sits in the corner and moves past the check only while it
      // shows.
      Color.clear
        .allowsHitTesting(false)
        .overlay(alignment: .topLeading) {
          activityPill
            .padding(.leading, chrome.pillLeadingInset)
            // The heart's corner stays clear: a narrow tile drops the word instead of covering it.
            .padding(.trailing, LibraryTileChrome.controlRoom)
        }
        .overlay(alignment: .topLeading) {
          if chrome.showsCheck || keepsHiddenControls {
            TileCheck(isOn: isChecked, isArming: isArming, title: row.title) {
              model.toggleChecked(row.id)
            }
            .opacity(chrome.showsCheck ? 1 : 0)
            .allowsHitTesting(chrome.showsCheck)
          }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: chrome.showsCheck)
    }
    .topTrailingBadge {
      if chrome.showsHeart || keepsHiddenControls {
        TileHeart(isOn: isFavorite, title: row.title, isBusy: isFavoriteBusy) {
          model.toggleFavorite(row.id)
        }
        .opacity(chrome.showsHeart ? 1 : 0)
        .allowsHitTesting(chrome.showsHeart)
      }
    }
    .bottomTrailingBadge { markBadges(marks) }
    .scaleEffect(isArming ? 0.97 : 1)
    .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: isArming)
    .onTapGesture { click(model) }
    .onHover { hovering in
      isHovering = hovering
      if hovering { model.pointerEntered(row.id) } else { model.pointerLeft(row.id) }
    }
    .onChange(of: isFocused) { model.focusChanged(row.id, isFocused: isFocused) }
    .onGeometryChange(for: CGSize.self, of: \.size) { model.geometry.cellSize = $0 }
    .accessibilityValue(Text(verbatim: marks.names.joined(separator: ", ")))
    .accessibilityAddTraits(.isButton)
    .accessibilityAction { model.tileActivated(row.id) }
    .accessibilityAction(named: Text("Apply wallpaper")) { model.activate(row.id) }
    .accessibilityIdentifier("installed-tile-\(row.id)")
  }

  // MARK: Artwork

  /// The cover once its stamp is known, and the quiet placeholder until then and for a wallpaper
  /// with no preview; the one tile that plays its animation draws it over the cover.
  private func artwork(_ model: InstalledBrowserModel) -> some View {
    ZStack {
      PanelImage(source: row.coverSource, pointSize: 190)
      if LibraryTileChrome.showsPlaceholder(
        hasCover: row.coverSource != nil, hasApplyState: hasApplyState)
      {
        Image(systemName: "photo")
          .font(.system(size: 22, weight: .regular))
          .foregroundStyle(theme.surface.faint.color)
      }
      if let live = model.livePreview, live.id == row.id {
        AnimatedPreview(data: live.data, isPlaying: true)
      }
      applyState
    }
  }

  private var hasApplyState: Bool {
    controller.applyingWallpaperID == row.id || controller.queuedApplyIDs.contains(row.id)
  }

  /// A status ring over the cover while the wallpaper is being applied, and a quiet one while its
  /// switch waits behind another. Neither takes clicks: waiting is progress, not an error, and it
  /// never blocks the tile.
  @ViewBuilder
  private var applyState: some View {
    if controller.applyingWallpaperID == row.id {
      ZStack {
        Color.black.opacity(0.5)
        VStack(spacing: 5) {
          ProgressRing(value: nil, lineWidth: 2.5).frame(width: 26, height: 26)
          Text("Applying").font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(.white)
      }
      .allowsHitTesting(false)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(Text(verbatim: L("Applying \(row.title)")))
      .accessibilityAddTraits(.updatesFrequently)
    } else if controller.queuedApplyIDs.contains(row.id) {
      ZStack {
        Color.black.opacity(0.4)
        Image(systemName: "play.fill")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(.white)
          .frame(width: 30, height: 30)
          .background(.white.opacity(0.18), in: Circle())
      }
      .allowsHitTesting(false)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(Text(verbatim: L("\(row.title) is waiting to be applied")))
    }
  }

  // MARK: Pills and marks

  /// Active on the target display, with the equalizer while it plays; Other display when another
  /// display shows it. A tile too narrow for the word keeps the equalizer or the display glyph
  /// alone.
  @ViewBuilder
  private var activityPill: some View {
    if row.isActive {
      ViewThatFits(in: .horizontal) {
        CapsuleBadge(style: .accent) {
          Equalizer(isPlaying: !controller.isPlaybackPaused, barWidth: 1.8, height: 9)
          Text("Active")
        }
        CapsuleBadge(style: .accent) {
          Equalizer(isPlaying: !controller.isPlaybackPaused, barWidth: 1.8, height: 9)
        }
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(Text("Active"))
      .accessibilityIdentifier("installed-tile-active")
    } else if otherDisplayIDs.contains(row.id) {
      ViewThatFits(in: .horizontal) {
        CapsuleBadge(style: .overlay) { Text("Other display") }
        CapsuleBadge(style: .overlay) { Image(systemName: "display").font(.system(size: 9)) }
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(Text("Other display"))
    }
  }

  @ViewBuilder
  private func markBadges(_ marks: LibraryTileMarks) -> some View {
    if marks.isApproved || marks.hasUpdate {
      HStack(spacing: 4) {
        if marks.isApproved {
          TileMark(systemImage: "trophy.fill", color: theme.surface.approved.color)
            .help(L("Approved by Wallpaper Engine"))
        }
        if marks.hasUpdate {
          TileMark(systemImage: "arrow.down", color: theme.accent.control.color)
            .help(L("Update available"))
        }
      }
    }
  }

  // MARK: Interaction

  private var isFavoriteBusy: Bool {
    controller.isBusy(PanelActionCoordinator.key("favorite", id: row.id))
  }

  /// A click: the keys held are the keyboard's own state, since no SwiftUI gesture says them.
  private func click(_ model: InstalledBrowserModel) {
    model.tileClicked(row.id, modifiers: NSEvent.modifierFlags)
  }
}

// MARK: - Tile controls

/// A round control over artwork: a dark glass disc with a white glyph, or a white disc with a
/// coloured one when it is on.
private struct TileDisc: View {
  let systemImage: String
  var isOn = false
  var onColor: Color
  var onFill: Color = .white.opacity(0.94)

  var body: some View {
    Image(systemName: systemImage)
      .font(.system(size: 12, weight: .bold))
      .foregroundStyle(isOn ? onColor : .white)
      .frame(width: LibraryGridGeometry.controlSize, height: LibraryGridGeometry.controlSize)
      .background(isOn ? onFill : .black.opacity(0.42), in: Circle())
      .overlay { Circle().strokeBorder(.white.opacity(isOn ? 0 : 0.35), lineWidth: 0.75) }
      .contentShape(Circle())
  }
}

/// A button whose pressed state dims it, which a plain style would not show over artwork.
private struct DiscButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.opacity(configuration.isPressed ? 0.7 : 1)
  }
}

/// The check that ticks a tile for a batch action. While a hold on the tile is arming it fills with
/// the accent over the hold, so the tile is seen to be about to be ticked.
private struct TileCheck: View {
  let isOn: Bool
  let isArming: Bool
  let title: String
  let action: () -> Void

  @Environment(\.panelTheme) private var theme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let isFilled = isOn || isArming
    Button(action: action) {
      // An unticked check is a hollow ring, as in Photos; the mark appears once it is ticked.
      Image(systemName: "checkmark")
        .font(.system(size: 12, weight: .bold))
        .foregroundStyle(theme.accent.onPrimary.color)
        .opacity(isOn ? 1 : 0)
        .frame(width: LibraryGridGeometry.controlSize, height: LibraryGridGeometry.controlSize)
        .background {
          ZStack {
            Circle().fill(.black.opacity(0.42))
            // The hold's 350 ms, as long as the tile takes to sink in; a ticked check is full.
            Circle().fill(theme.accent.primary.color)
              .scaleEffect(isFilled ? 1 : 0.01)
              .animation(
                isOn || reduceMotion ? nil : .easeIn(duration: 0.35), value: isFilled)
          }
        }
        .overlay { Circle().strokeBorder(.white.opacity(isFilled ? 0 : 0.7), lineWidth: 1.25) }
        .contentShape(Circle())
    }
    .buttonStyle(DiscButtonStyle())
    .help(L("Click to select, or drag from here across other tiles to select them too."))
    .accessibilityLabel(Text(verbatim: isOn ? L("Deselect: \(title)") : L("Select: \(title)")))
    .accessibilityAddTraits(isOn ? .isSelected : [])
  }
}

/// The heart that makes a wallpaper a favorite. It rests as a filled heart on a favorite and shows
/// itself, outlined, only for a tile that is hovered or focused.
private struct TileHeart: View {
  let isOn: Bool
  let title: String
  let isBusy: Bool
  let action: () -> Void

  @Environment(\.panelTheme) private var theme

  var body: some View {
    Button(action: action) {
      TileDisc(
        systemImage: isOn ? "heart.fill" : "heart", isOn: isOn, onColor: theme.surface.heart.color)
    }
    .buttonStyle(DiscButtonStyle())
    .disabled(isBusy)
    .help(isOn ? L("Remove favorite: \(title)") : L("Add favorite: \(title)"))
    .accessibilityLabel(
      Text(verbatim: isOn ? L("Remove favorite: \(title)") : L("Add favorite: \(title)")))
    .accessibilityAddTraits(isOn ? .isSelected : [])
  }
}

/// A small white disc with a coloured glyph: approved, update available.
private struct TileMark: View {
  let systemImage: String
  let color: Color

  var body: some View {
    Image(systemName: systemImage)
      .font(.system(size: 9.5, weight: .bold))
      .foregroundStyle(color)
      .frame(width: 18, height: 18)
      .background(.white.opacity(0.94), in: Circle())
  }
}
