import AppKit
import SwiftUI

/// One work in the pixiv grid: its picture with the corner marks and the download ring, its title
/// and artist beneath.
///
/// The cell asks the controller for its own download state, so a progress tick re-renders only the
/// tile whose page moved. A click selects the work, a double click saves the page the inspector
/// shows (or applies it once saved), and the ring's own button cancels, resumes or retries
/// without selecting. VoiceOver reaches the same: the tile is a button that selects, with the
/// double-click as a named action.
struct PixivTileCell: View {
  let work: PixivWork
  let isSelected: Bool

  @Environment(PanelController.self) private var controller
  /// The tile is too small for every corner mark (`PixivTileCorners`). It starts roomy, the size
  /// most windows draw, and changes only when the tile crosses the threshold.
  @State private var isCompact = false

  var body: some View {
    let model = controller.pixivBrowser
    let tile = controller.pixivTile(for: work)
    let facts = PixivTileFacts(tile)
    let corners = PixivTileCorners(facts, isCompact: isCompact)
    WallpaperTile(
      title: work.displayTitle, subtitle: work.authorName.isEmpty ? nil : work.authorName,
      kind: facts.spoken, isSelected: isSelected
    ) {
      PixivTileArtwork(tile: tile) { ring in model.pressRing(ring) }
    }
    .topLeadingBadge { PixivTileLeadingMarks(corners: corners) }
    .topTrailingBadge { PixivTileBadges(corners: corners) }
    .bottomTrailingBadge { PixivTilePageCount(corners: corners) }
    // One tap handler tells a click from a double-click by the event itself, as the Workshop tile
    // does. The ring is a button of its own and takes its clicks first, so a double-click on the
    // ring never also runs the tile's double-click (which, with the save just cancelled, would
    // queue it again).
    .onTapGesture {
      if NSApp.currentEvent?.clickCount == 2 { model.doubleClick(work) } else { model.select(work) }
    }
    .onGeometryChange(for: Bool.self) {
      PixivTileCorners.isCompact(side: $0.size.width)
    } action: {
      isCompact = $0
    }
    .accessibilityAddTraits(.isButton)
    .accessibilityAction { model.select(work) }
    // The named action is built inside the actions list, so it can come and go (a download
    // starts, a page is saved) without changing the tile's identity and rebuilding its picture.
    .accessibilityActions {
      if let name = doubleClickName(tile) {
        Button(name) { model.doubleClick(work) }
      }
    }
    .accessibilityIdentifier("pixiv-tile-\(work.id)")
  }

  /// What a double-click on the tile does, for VoiceOver's actions menu: "Download" or "Apply
  /// wallpaper", nothing while the page downloads or when no display could show it. It is worked
  /// out from the tile's own saves and the page the inspector shows, the way the double-click
  /// decides (`PixivDoubleClick`), but never from a download's progress, so a progress tick does
  /// not redraw every tile.
  private func doubleClickName(_ tile: PixivTile) -> String? {
    let pixiv = controller.pixiv
    let page = pixiv.selectedWork?.id == work.id ? pixiv.selectedPage : 0
    let pending = Set(
      pixiv.downloads.downloads.lazy.filter { $0.work.id == work.id && $0.isPending }.map(\.id))
    let decision = PixivDoubleClick.decide(
      workID: work.id, page: page, savedPages: tile.savedPages, pendingJobIDs: pending,
      targetCanShowWallpaper: controller.mediaApplyTarget.canShowWallpaper)
    switch decision {
    case .apply: return L("Apply wallpaper")
    case .download: return L("Download")
    case .nothing: return nil
    }
  }

  /// What a click on the ring does: the job it names is a library id.
  @MainActor
  static func perform(_ ring: PixivTile.Ring, in controller: PanelController) async throws {
    switch ring.state.action {
    case .resume: try await controller.pixivResume(id: ring.jobID)
    case .cancel: try await controller.pixivCancel(id: ring.jobID)
    case .retry: try await controller.pixivRetryDownload(id: ring.jobID)
    case .continueSetup: break
    }
  }
}

/// The picture of a tile, dimmed while a ring is over it.
private struct PixivTileArtwork: View {
  let tile: PixivTile
  let ringAction: (PixivTile.Ring) -> Void

  var body: some View {
    ZStack {
      PanelImage(source: tile.image, pointSize: 180)
        .saturation(tile.ring == nil ? 1 : 0.85)
        .brightness(tile.ring == nil ? 0 : -0.28)
      if let ring = tile.ring {
        PixivTileRing(state: ring.state) { ringAction(ring) }
      }
    }
  }
}

/// The marks in a tile's top leading corner: the saved check, and on a compact tile R-18 beneath
/// it, where no other corner's mark can meet them.
private struct PixivTileLeadingMarks: View {
  let corners: PixivTileCorners

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      if corners.showsSaved { PixivSavedMark(isCompact: corners.isCompact) }
      if corners.isCompact, corners.showsMature { PixivMatureBadge(isCompact: true) }
    }
  }
}

/// The check in the corner of a tile of which a page is in the library.
private struct PixivSavedMark: View {
  let isCompact: Bool

  var body: some View {
    Image(systemName: "checkmark")
      .font(.system(size: isCompact ? 8 : 9.5, weight: .bold))
      .foregroundStyle(.white)
      .frame(width: isCompact ? 16 : 20, height: isCompact ? 16 : 20)
      .background(.black.opacity(0.6), in: Circle())
      .help(L("In your library"))
      .accessibilityHidden(true)
  }
}

/// The R-18 capsule, in pixiv's red whatever the appearance, since it sits over artwork.
private struct PixivMatureBadge: View {
  let isCompact: Bool

  var body: some View {
    Text(verbatim: "R-18")
      .font(.system(size: isCompact ? 9 : 11, weight: .bold))
      .foregroundStyle(.white)
      .padding(.horizontal, isCompact ? 4 : 7)
      .frame(minHeight: isCompact ? 14 : 18)
      .background(Color(red: 0.84, green: 0.157, blue: 0.231), in: Capsule())
      .accessibilityHidden(true)
  }
}

/// The marks in a roomy tile's top trailing corner: the ranking and R-18. They are decoration; the
/// tile's accessibility label carries the same facts.
private struct PixivTileBadges: View {
  let corners: PixivTileCorners

  var body: some View {
    if !corners.isCompact {
      VStack(alignment: .trailing, spacing: 4) {
        if let rank = corners.rank {
          CapsuleBadge(style: .overlay) { Text(verbatim: "#\(rank)") }
        }
        if corners.showsMature { PixivMatureBadge(isCompact: false) }
      }
      .accessibilityHidden(true)
    }
  }
}

/// The number of pages of a work that has several, in a roomy tile's bottom trailing corner.
private struct PixivTilePageCount: View {
  let corners: PixivTileCorners

  var body: some View {
    if let pages = corners.pageCount {
      CapsuleBadge(style: .overlay) {
        Image(systemName: "square.2.layers.3d.fill").font(.system(size: 9))
        Text(verbatim: "\(pages)")
      }
      .accessibilityHidden(true)
    }
  }
}
