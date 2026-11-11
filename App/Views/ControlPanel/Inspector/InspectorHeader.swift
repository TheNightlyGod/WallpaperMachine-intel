import SwiftUI

/// The top of the inspector: the wallpaper's preview, its name and facts, the main actions and its
/// tags.
struct InspectorHeader: View {
  let row: LibraryRow

  @Environment(\.panelTheme) private var theme

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      InspectorArtwork(row: row)
      VStack(alignment: .leading, spacing: 4) {
        // A wallpaper's own title: text, never a catalog key.
        Text(verbatim: row.title)
          .font(.system(size: 17, weight: .bold))
          .foregroundStyle(theme.surface.text.color)
          .lineLimit(4)
          .frame(maxWidth: .infinity, alignment: .leading)
          .textSelection(.enabled)
          .accessibilityAddTraits(.isHeader)
        Text(verbatim: InspectorWording.meta(for: row))
          .font(.system(size: 12))
          .foregroundStyle(theme.surface.muted.color)
          .frame(maxWidth: .infinity, alignment: .leading)
          .textSelection(.enabled)
        if let rating = row.energy {
          Text(verbatim: InspectorWording.energyLine(rating))
            .font(.system(size: 11))
            .foregroundStyle(theme.surface.muted.color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .padding(.top, 2)
        }
      }
      InspectorActionRow(row: row)
      if !row.tags.isEmpty {
        TagFlow(spacing: 6) {
          ForEach(Array(row.tags.enumerated()), id: \.offset) { _, tag in TagChip(text: tag) }
        }
      }
    }
  }
}

/// The wallpaper's own preview file: a still while it loads, then the animation when the file is a
/// GIF, APNG or animated WebP. Only the selected wallpaper's preview ever plays, and only while the
/// window is on screen.
struct InspectorArtwork: View {
  let row: LibraryRow

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme
  @Environment(\.panelIsVisible) private var isVisible
  @State private var animation: Data?

  var body: some View {
    ZStack {
      theme.surface.mediaWell.color
      if row.previewFile == nil {
        Image(systemName: "photo")
          .font(.system(size: 30, weight: .light))
          .foregroundStyle(theme.surface.faint.color)
      } else {
        PanelImage(source: row.previewSource, pointSize: 420, contentMode: .fill)
        if animation != nil {
          AnimatedPreview(data: animation, isPlaying: isVisible, contentMode: .fill)
        }
      }
    }
    .aspectRatio(16.0 / 10.0, contentMode: .fit)
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .strokeBorder(theme.surface.divider.color, lineWidth: 0.5)
    }
    .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
    .accessibilityHidden(true)
    // Hidden, the request becomes nil and the animation's bytes go; the still stays under it.
    .task(id: isVisible ? row.animationSource : nil) { await loadAnimation() }
  }

  private func loadAnimation() async {
    animation = nil
    guard isVisible, let source = row.animationSource else { return }
    // A preview that is a single frame, or too large to animate, keeps its still.
    let data = try? await controller.images.animation(for: source)
    guard !Task.isCancelled else { return }
    animation = data
  }
}

/// A blurred, saturated wash of the wallpaper's still across the top of the inspector, fading out
/// below the preview. It is a still, never the animation: a blurred animation would be redrawn
/// every frame.
struct InspectorWash: View {
  let row: LibraryRow

  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    PanelImage(source: row.coverSource ?? row.previewSource, pointSize: 256, contentMode: .fill)
      .scaleEffect(1.3)
      .blur(radius: 48)
      .saturation(1.6)
      .opacity(colorScheme == .dark ? 0.55 : 0.38)
      .frame(height: 320)
      .clipped()
      .mask {
        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
      }
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }
}

/// Apply, favorite and the menu of everything else.
struct InspectorActionRow: View {
  let row: LibraryRow

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let target = controller.targetDisplay
    let offer = ApplyOffer(
      wallpaperID: row.id, shownID: target?.wallpaperID,
      canApply: InspectorPolicy.canActivate(kind: row.kind, target: target),
      isBusy: { controller.isBusy($0) })
    let isFavorite = controller.favoriteIDs.contains(row.id)
    let favoriteKey = PanelActionCoordinator.key("favorite", id: row.id)
    HStack(spacing: 8) {
      Button {
        controller.launch(offer.key) { try await controller.apply(offer) }
      } label: {
        Group {
          if offer.reapplies {
            Label("Reapply wallpaper", systemImage: "arrow.clockwise")
          } else {
            Label("Apply wallpaper", systemImage: "play.fill")
          }
        }
        // The narrowest inspector shrinks the words a little rather than cutting them off.
        .minimumScaleFactor(0.8)
      }
      .buttonStyle(.panelPrimary(size: .regular, expands: true))
      .disabled(!offer.isEnabled)
      .help(offer.reapplies ? L("Reapply wallpaper") : L("Apply wallpaper"))
      .accessibilityIdentifier("inspector.apply")

      Button {
        controller.launch(favoriteKey) { try await controller.toggleFavorite(row.id) }
      } label: {
        Image(systemName: isFavorite ? "heart.fill" : "heart")
      }
      .buttonStyle(
        InspectorIconButtonStyle(activeTint: theme.surface.heart.color, isActive: isFavorite)
      )
      .disabled(controller.isBusy(favoriteKey))
      .help(isFavorite ? L("Remove from favorites") : L("Add to favorites"))
      .accessibilityLabel(isFavorite ? L("Remove from favorites") : L("Add to favorites"))
      .accessibilityIdentifier("inspector.favorite")

      InspectorMoreMenu(row: row)
    }
  }
}

/// Preview, Show in Finder, Share, Apply to all displays, the playlist, Reinstall, the problem
/// report and the Trash: the items a right click on the wallpaper's tile offers too
/// (`WallpaperActionItems`).
struct InspectorMoreMenu: View {
  let row: LibraryRow

  @Environment(PanelController.self) private var controller

  var body: some View {
    Menu {
      WallpaperActionItems(row: row, placement: .inspector)
    } label: {
      Image(systemName: "ellipsis")
    }
    .menuStyle(.button)
    .menuIndicator(.hidden)
    .buttonStyle(InspectorIconButtonStyle())
    .fixedSize()
    .help(L("More actions"))
    .accessibilityLabel(L("More actions"))
    .accessibilityIdentifier("inspector.more")
    // The subscription item's label needs the account's subscriptions, as Discover's tiles do;
    // asked again for another wallpaper or sign-in, which also retries a read that failed.
    .task(id: "\(row.id) \(controller.workshop.steamWebSession?.steamID ?? "")") {
      if InspectorPolicy.isWorkshopID(row.id) { controller.workshopBrowser.readSubscriptionsOnce() }
    }
  }
}
