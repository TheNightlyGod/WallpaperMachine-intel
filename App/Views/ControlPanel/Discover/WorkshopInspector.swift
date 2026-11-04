import SwiftUI

/// The inspector beside the Steam Workshop page: the selected item's preview, who made it and how big
/// it is, what its download is doing and what can be done about it, its tags and its description.
///
/// The download controls follow one request or job (`WorkshopItemDownload`): a collection is opened;
/// a retained request is resumed or continued; a running download is watched or cancelled; anything
/// else is downloaded, and **Download and apply** sits beside it only where the wallpaper can run and
/// the target display can show it. An item that is already installed trades them for what can be done
/// with the installed copy. All of the text here can be selected and copied.
struct WorkshopInspector: View {
  @Environment(PanelController.self) private var controller

  var body: some View {
    if let item = controller.workshopSelectedItem {
      ItemInspector(item: item)
    } else {
      PanelEmptyState(
        "Select a wallpaper", systemImage: "photo",
        description: "Preview, details and options appear here.")
    }
  }
}

// MARK: - One item

private struct ItemInspector: View {
  let item: WorkshopItem

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme
  @Environment(\.locale) private var locale

  var body: some View {
    let download = controller.workshopItemDownload(for: item)
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        InspectorPreview(item: item, isInstalled: download.isInstalled)
        heading
        WorkshopItemActions(item: item, download: download)
        tags
        WorkshopDownloadNotes(item: item, download: download)
        summary
        if !item.isCollection, item.authorProfileID != nil { WorkshopItemComments(item: item) }
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .foregroundStyle(theme.surface.text.color)
    }
    .scrollBounceBehavior(.basedOnSize)
    .accessibilityIdentifier("workshop-inspector")
  }

  // MARK: Heading

  private var heading: some View {
    VStack(alignment: .leading, spacing: 3) {
      // Everything here is the Workshop's text, so none of it is read as a catalog key.
      Text(verbatim: item.title)
        .font(.system(size: 17, weight: .bold))
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .accessibilityAddTraits(.isHeader)
      if !item.creator.isEmpty {
        HStack(spacing: 8) {
          Text(verbatim: item.creator)
            .font(.system(size: 12.5))
            .foregroundStyle(theme.surface.muted.color)
            .lineLimit(1)
            .textSelection(.enabled)
          if showsAuthorLink {
            Button("More by this author") { controller.workshopBrowser.openAuthor(of: item) }
              .buttonStyle(.panelLink)
              .font(.system(size: 12))
          }
        }
      }
      meta
        .font(.system(size: 12))
        .foregroundStyle(theme.surface.muted.color)
        .textSelection(.enabled)
    }
  }

  /// The author's other wallpapers, unless those are what is on show already.
  private var showsAuthorLink: Bool {
    guard let id = item.authorProfileID else { return false }
    let source = controller.workshopBrowse.source.source
    if case .creator(let shown, _) = source, shown == id { return false }
    return true
  }

  /// "Scene · 268 MB · 48,200 subscribers": the kind, how big, how many people subscribe. The count
  /// is a number of the panel's language, grouped as it groups its numbers.
  private var meta: Text {
    var parts = [item.kindLabel]
    if item.isCollection, let size = item.collectionSize, size > 0 {
      parts.append(size == 1 ? L("1 item") : L("\(size) items"))
    } else {
      let bytes = TransferFormat.bytes(Double(item.size), locale: locale)
      if !bytes.isEmpty { parts.append(bytes) }
    }
    return Text(verbatim: parts.joined(separator: " · ") + " · ")
      + Text("\(item.subscriptions) subscribers")
  }

  // MARK: Tags and description

  @ViewBuilder
  private var tags: some View {
    if !item.tags.isEmpty {
      TagFlow(spacing: 6) {
        ForEach(item.tags, id: \.self) { TagChip(text: $0) }
      }
    }
  }

  @ViewBuilder
  private var summary: some View {
    if !item.summary.isEmpty {
      PanelCard {
        Text(verbatim: item.summary)
          .font(.system(size: 12.5))
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(12)
          .textSelection(.enabled)
      }
    }
  }
}

// MARK: - Preview

/// The item's picture at 16:10, with its animation playing over it for as long as it is selected and
/// the window is on screen. A wallpaper that is installed shows the library's own preview, with the
/// button that applies it.
private struct InspectorPreview: View {
  let item: WorkshopItem
  let isInstalled: Bool

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme
  @Environment(\.panelIsVisible) private var isVisible
  @State private var animation: (id: String, data: Data)?

  var body: some View {
    let source = still
    Color.clear
      .aspectRatio(16.0 / 10.0, contentMode: .fit)
      .overlay {
        ZStack {
          PanelImage(source: source, pointSize: 420)
          if let animation, animation.id == item.id, !isInstalled {
            AnimatedPreview(data: animation.data, isPlaying: isVisible)
          }
        }
      }
      .overlay(alignment: .bottomTrailing) {
        if isInstalled { ApplyButton(item: item).padding(10) }
      }
      .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .strokeBorder(theme.surface.divider.color, lineWidth: 0.5)
      }
      .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
      .accessibilityHidden(true)
      // Hidden, the request becomes nil and the animation's bytes go; the still stays under it.
      .task(id: isVisible ? item.id : nil) { await loadAnimation() }
  }

  private var still: PanelImageSource? {
    if isInstalled, let preview = controller.libraryRow(id: item.id)?.previewSource {
      return preview
    }
    return item.thumbnail
  }

  /// Steam's animation for the selected item alone: one at a time, held to the pipeline's budget.
  private func loadAnimation() async {
    animation = nil
    guard isVisible, !isInstalled, let source = item.thumbnail else { return }
    guard let data = try? await controller.images.animation(for: source) else { return }
    guard !Task.isCancelled else { return }
    animation = (item.id, data)
  }
}

/// The round play button over an installed wallpaper's picture: Apply, or Reapply when the target
/// display shows it already (applying what is shown does nothing, so that restarts it).
private struct ApplyButton: View {
  let item: WorkshopItem

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    // An Application, or a type the library cannot name, cannot be applied.
    let kind = controller.libraryRow(id: item.id)?.kind ?? .unknown
    let offer = ApplyOffer(
      wallpaperID: item.id, target: controller.mediaApplyTarget,
      canRun: item.canRunOnMac && kind != .unknown, isBusy: { controller.isBusy($0) })
    let label = offer.reapplies ? L("Reapply wallpaper") : L("Apply wallpaper")
    Button {
      controller.launch(offer.key) { [controller] in try await controller.apply(offer) }
    } label: {
      Image(systemName: offer.reapplies ? "arrow.clockwise" : "play.fill")
        .font(.system(size: 14, weight: .bold))
        .foregroundStyle(theme.accent.onPrimary.color)
        .frame(width: 38, height: 38)
        .background(theme.accent.primary.color, in: Circle())
        .shadow(color: .black.opacity(0.3), radius: 4, y: 1)
    }
    .buttonStyle(.plain)
    .disabled(!offer.isEnabled)
    .help(label)
    .accessibilityLabel(Text(verbatim: label))
    .accessibilityIdentifier("workshop-inspector-apply")
  }
}
