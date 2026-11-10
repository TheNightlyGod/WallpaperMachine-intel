import SwiftUI

/// What the Installed grid says when it has no tiles, and the way out of each case: import
/// something, put the filters away, or show everything again. Its words can be selected and
/// copied, a search term among them.
struct InstalledEmptyState: View {
  let state: LibraryEmptyState

  @Environment(PanelController.self) private var controller

  var body: some View {
    let model = controller.library
    Group {
      switch state {
      case .loading:
        PanelEmptyState(
          "Loading wallpapers", systemImage: "photo.stack",
          description: "Reading your wallpaper library."
        )
        .textSelectable()
      case .failed(let message):
        // An error keeps its symbol whatever the season, and its reason is the service's own words.
        PanelEmptyState(
          verbatim: L("Your wallpaper library could not be read"),
          systemImage: "exclamationmark.triangle", description: message
        ) {
          Button {
            model.refreshLibrary()
          } label: {
            Label("Try again", systemImage: "arrow.clockwise")
          }
          .buttonStyle(.panelSecondary)
          .disabled(controller.isBusy(PanelActionCoordinator.key("refresh")))
        }
        .textSelectable()
      case .emptyLibrary:
        PanelEmptyState(
          "Your wallpaper library is empty", systemImage: "photo.on.rectangle.angled",
          description: "Import a wallpaper folder or find something on the Workshop."
        ) {
          HStack(spacing: 8) {
            Button("Import wallpapers") { model.openImport(from: .page) }
              .buttonStyle(.panelCapsule)
            Button("Browse Workshop") {
              controller.launch(PanelActionCoordinator.key("navigate"), policy: .latestWins) {
                try await controller.navigate(.workshop)
              }
            }
            .buttonStyle(.panelPrimary)
          }
        }
        .textSelectable()
        .seasonalArt(.emptyLibrary)
      case .emptyCollection(let name):
        PanelEmptyState(
          "No matching wallpapers", systemImage: "folder",
          description: "“\(name)” has no wallpapers yet. Select wallpapers and choose Add to collection."
        ) {
          Button("Show all wallpapers") { model.showAllWallpapers() }
            .buttonStyle(.panelCapsule)
        }
        .textSelectable()
      case .searchAndFilters:
        PanelEmptyState(
          "No matching wallpapers", systemImage: "magnifyingglass",
          description: "Change your search or clear filters to see more wallpapers."
        ) {
          Button("Clear search and filters") { model.clearSearchAndFilters() }
            .buttonStyle(.panelCapsule)
        }
        .textSelectable()
        .seasonalArt(.noResults)
      case .notInstalled(let id):
        PanelEmptyState(
          "Not in your library", systemImage: "arrow.down.circle",
          description: "Workshop item \(id) is not installed."
        ) {
          HStack(spacing: 8) {
            Button("Clear search") { model.clearSearch() }
              .buttonStyle(.panelCapsule)
            Button("Show in Steam Workshop") { controller.workshopBrowser.lookUp(itemID: id) }
              .buttonStyle(.panelPrimary)
          }
        }
        .textSelectable()
        .seasonalArt(.noResults)
      case .search(let text):
        PanelEmptyState(
          "No matching wallpapers", systemImage: "magnifyingglass",
          description: "No wallpaper matches “\(text)”."
        ) {
          Button("Clear search") { model.clearSearch() }
            .buttonStyle(.panelCapsule)
        }
        .textSelectable()
        .seasonalArt(.noResults)
      case .filters(let count):
        PanelEmptyState(
          "No matching wallpapers", systemImage: "line.3.horizontal.decrease",
          description: count == 1
            ? "The active filter hides every wallpaper."
            : "The \(count) active filters hide every wallpaper."
        ) {
          HStack(spacing: 8) {
            Button("Clear filters") { model.clearFilters() }
              .buttonStyle(.panelCapsule)
            if !controller.shell.areFiltersShown {
              Button("Show filters") { controller.shell.setFiltersShown(true) }
                .buttonStyle(.panelCapsule)
            }
          }
        }
        .textSelectable()
        .seasonalArt(.noResults)
      }
    }
    .accessibilityIdentifier("installed-empty")
  }
}
