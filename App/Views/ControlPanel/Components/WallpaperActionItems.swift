import SwiftUI

/// The actions on one installed wallpaper, as the items of a menu: the inspector's More menu and
/// the menu a right click on a library tile opens are the same list, so an action added to one is
/// in the other.
///
/// Every item acts on `row`, whichever wallpaper the inspector shows, so the tile's menu works on
/// the tile that was clicked without choosing it first. Which items are offered and when they are
/// enabled is `InspectorPolicy`'s, read when the menu opens: a closed menu costs a tile nothing.
struct WallpaperActionItems: View {
  /// Where the menu hangs, which decides what it leads with and what it leaves to its surroundings.
  enum Placement {
    /// Beside the inspector's Apply and favorite buttons, which the menu therefore does not repeat.
    /// It carries what belongs to the wallpaper's own page: sharing, its Workshop subscription and
    /// author, and the problem report.
    case inspector
    /// On a tile of the Installed grid: Apply and the favorite first, since a tile has no buttons
    /// for them that the keyboard or a right click reach.
    case tile
  }

  let row: LibraryRow
  let placement: Placement

  @Environment(PanelController.self) private var controller

  var body: some View {
    let target = controller.targetDisplay
    let shared = controller.standaloneDisplayRows
    let offersAll = InspectorPolicy.offersApplyToAll(row, sharedDisplayCount: shared.count)
    let everywhere = InspectorPolicy.appliesEverywhereAlready(
      row.id, sharedDisplayWallpapers: shared.map(\.wallpaperID))
    let playlist = InspectorPolicy.playlistToggle(
      row, target: target, listedIDs: target.map { controller.playlistState(for: $0.id).playlist.wallpaperIDs } ?? [])
    let canReinstall = controller.canReinstall(row.id)
    let issue = placement == .inspector ? controller.inspectorIssueReportURL(for: row) : nil
    if placement == .tile {
      Button {
        controller.library.activate(row.id)
      } label: {
        Label("Apply wallpaper", systemImage: "play.fill")
      }
      .disabled(!InspectorPolicy.canActivate(kind: row.kind, target: target))
      favorite
      Divider()
    }
    if InspectorPolicy.offersPreview(kind: row.kind, previewAvailable: controller.previewAvailable) {
      Button {
        controller.launch(PanelActionCoordinator.key("previewWallpaper", id: row.id)) {
          try await controller.previewWithTypedText(row.id)
        }
      } label: {
        Label("Preview wallpaper", systemImage: "eye")
      }
      .help(L("Open a live preview without changing your desktop"))
    }
    Button {
      controller.launch(PanelActionCoordinator.key("reveal", id: row.id)) {
        try await controller.reveal(row.id)
      }
    } label: {
      Label("Show in Finder", systemImage: "folder")
    }
    if placement == .inspector {
      // Only a Workshop wallpaper has a page to share.
      if let share = controller.wallpaperShare(row.id) {
        ShareLink(
          item: share.url, subject: Text(verbatim: share.subject),
          message: Text(verbatim: share.message)
        ) {
          Label("Share…", systemImage: "square.and.arrow.up")
        }
      }
      if isWorkshop {
        if controller.workshop.steamWebSession != nil { subscription }
        Button {
          controller.launch(PanelActionCoordinator.key("workshopCreator", id: row.id)) {
            try await controller.openInstalledWorkshopAuthor(id: row.id)
          }
        } label: {
          Label("More by this author", systemImage: "person.crop.rectangle.stack")
        }
      }
    }
    if offersAll {
      Button {
        controller.launch(PanelActionCoordinator.key("activateAll", id: row.id)) {
          try await controller.activateAll(row.id)
        }
      } label: {
        Label("Apply to all displays", systemImage: "display.2")
      }
      .disabled(everywhere)
    }
    switch playlist {
    case .hidden: EmptyView()
    case .enabled(let isListed), .disabled(let isListed):
      let enabled = playlist == .enabled(isListed: isListed)
      Button {
        controller.launch(PanelActionCoordinator.key("playlist", id: row.id)) {
          if isListed {
            try await controller.removeFromPlaylist(row.id)
          } else {
            try await controller.addToPlaylist([row.id])
          }
        }
      } label: {
        if isListed {
          Label("Remove from this display’s playlist", systemImage: "text.badge.minus")
        } else {
          Label("Add to this display’s playlist", systemImage: "text.badge.plus")
        }
      }
      .disabled(!enabled)
    }
    if canReinstall {
      Button {
        controller.launch(PanelActionCoordinator.key("workshopReinstall", id: row.id)) {
          try await controller.reinstallWorkshopItem(id: row.id)
        }
      } label: {
        Label("Reinstall from Workshop…", systemImage: "arrow.triangle.2.circlepath")
      }
    }
    Divider()
    if let issue {
      Button {
        ExternalLink.open(issue)
      } label: {
        Label("Report this problem on GitHub", systemImage: "exclamationmark.bubble")
      }
    }
    Button(role: .destructive) {
      controller.launch(PanelActionCoordinator.key("delete", id: row.id)) {
        try await controller.delete(row.id)
      }
    } label: {
      Label("Move wallpaper to Trash", systemImage: "trash")
    }
    .disabled(!controller.canMoveToTrash(row.id))
  }

  private var isWorkshop: Bool { InspectorPolicy.isWorkshopID(row.id) }

  /// The tile's heart, for a tile whose heart only shows on hover.
  private var favorite: some View {
    let isFavorite = controller.favoriteIDs.contains(row.id)
    return Button {
      controller.library.toggleFavorite(row.id)
    } label: {
      if isFavorite {
        Label("Remove from favorites", systemImage: "heart.slash")
      } else {
        Label("Add to favorites", systemImage: "heart")
      }
    }
    .disabled(controller.isBusy(PanelActionCoordinator.key("favorite", id: row.id)))
  }

  /// **Subscribe on Steam** or **Unsubscribe on Steam**, for the signed-in Steam Community account,
  /// as in Discover's inspector.
  private var subscription: some View {
    let subscribed = controller.workshop.subscribedIDs.contains(row.id)
    let key = PanelActionCoordinator.key("workshopSubscription", id: row.id)
    return Button {
      controller.launch(key) { try await controller.setInstalledWorkshopSubscribed(!subscribed, id: row.id) }
    } label: {
      if subscribed {
        Label("Unsubscribe on Steam", systemImage: "bookmark.slash")
      } else {
        Label("Subscribe on Steam", systemImage: "bookmark")
      }
    }
    // Until Steam has answered for this account, a missing mark may be a subscription after all.
    .disabled(controller.isBusy(key) || !controller.workshop.subscriptionsKnown)
  }
}
