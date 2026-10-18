import SwiftUI

/// The inspector beside the Installed page: the selected wallpaper's preview, actions and options.
///
/// Top to bottom: the header (preview, name, facts, Apply, favorite, the menu, tags), what the app
/// has to say about the wallpaper, the Compatibility check, Black bars (video) and Position on
/// screen (a still image the app packaged), then the wallpaper's own settings: General
/// configuration, Displays, Collections, Presets and the authored properties. A footer holds Revert
/// and Apply changes once the options are loaded.
struct InstalledInspector: View {
  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    Group {
      // The row is nil for a wallpaper that is not installed (a stale selection).
      if let id = controller.selectedWallpaperID, let row = controller.libraryRow(id: id) {
        // Keyed by the wallpaper: another one starts at the top, with the sections open as they
        // are by default and nothing typed or picked left over.
        InspectorContent(row: row).id(id)
      } else {
        PanelEmptyState(
          "Select a wallpaper", systemImage: "photo",
          description: "Preview, details and options appear here.")
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(theme.surface.background.color)
    // Every link in the inspector goes through the panel's allowlist.
    .environment(
      \.openURL, OpenURLAction { url in ExternalLink.open(url) ? .handled : .discarded }
    )
    .onChange(of: controller.imagePlacementState, initial: true) { _, state in
      controller.inspector.placement.observe(state)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(L("Wallpaper details"))
  }
}

private struct InspectorContent: View {
  let row: LibraryRow

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let id = row.id
    let options = controller.inspectorOptions(for: id)
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        InspectorHeader(row: row)
        InspectorNotices(row: row)
        if let compatibility = controller.compatibilityState, compatibility.wallpaperID == id {
          CompatibilityCard(state: compatibility, row: row)
        }
        if let letterbox = controller.letterboxState, letterbox.wallpaperID == id {
          LetterboxCard(state: letterbox)
        }
        if InspectorPolicy.isPackagedStill(id), let placement = controller.imagePlacementState,
          placement.wallpaperID == id
        {
          PlacementCard(state: placement, row: row)
        }
        if let options {
          if !options.isSupported {
            InspectorNotice(tone: .warning) {
              Text("This wallpaper cannot be rendered on this Mac.")
            }
          }
          GeneralConfigurationCard(options: options)
          DisplaysCard(options: options)
          CollectionsCard(wallpaperID: id)
          PropertiesCards(options: options)
        } else {
          LoadingOptions()
          CollectionsCard(wallpaperID: id)
        }
      }
      .padding(16)
    }
    .background(alignment: .top) { InspectorWash(row: row) }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if let options { InspectorFooter(options: options) }
    }
  }
}

/// Shown until the bridge answers for this wallpaper.
private struct LoadingOptions: View {
  @Environment(\.panelTheme) private var theme

  var body: some View {
    HStack(spacing: 8) {
      ProgressRing(value: nil, lineWidth: 1.5).frame(width: 12, height: 12)
      Text("Loading wallpaper options…")
        .font(.system(size: 12))
        .foregroundStyle(theme.surface.muted.color)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 12)
    .accessibilityElement(children: .combine)
  }
}

/// Revert and Apply changes, with a line saying whether there is anything to apply.
struct InspectorFooter: View {
  let options: InspectorOptions

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let id = options.wallpaperID
    let applyKey = InspectorAction.apply(id)
    let revertKey = InspectorAction.revert(id)
    VStack(alignment: .leading, spacing: 8) {
      Group {
        if options.hasChanges {
          Text("You have unapplied changes.")
        } else {
          Text("Audio, scaling mode and frame rate update immediately.")
        }
      }
      .font(.system(size: 11.5))
      .foregroundStyle(theme.surface.muted.color)
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityElement(children: .combine)
      // A status line: the edit that leaves something to apply is followed by saying so.
      .announcing(options.hasChanges ? L("You have unapplied changes.") : nil)
      HStack(spacing: 8) {
        Button("Revert") {
          controller.launch(revertKey) { try await controller.revert(id) }
        }
        .buttonStyle(.inspectorSecondary(size: .regular, expands: true))
        .disabled(!options.canRevert || controller.isBusy(revertKey))
        .accessibilityIdentifier("inspector.revert")
        Button("Apply changes") {
          controller.launch(applyKey) { try await controller.apply(id) }
        }
        .buttonStyle(.panelPrimary(size: .regular, expands: true))
        .disabled(!options.canApply || controller.isBusy(applyKey))
        .accessibilityIdentifier("inspector.applyChanges")
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background(.bar)
    .overlay(alignment: .top) {
      Rectangle().fill(theme.surface.divider.color).frame(height: 0.5)
    }
  }
}
