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
        ItemActions(item: item, download: download)
        tags
        DownloadNotes(item: item, download: download)
        summary
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
      .task(id: item.id) { await loadAnimation() }
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
    guard !isInstalled, let source = item.thumbnail else { return }
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
    let target = controller.mediaApplyTarget
    let reapplies = target.wallpaperID == item.id
    // An Application, or a type the library cannot name, cannot be applied.
    let canActivate =
      item.canRunOnMac && (controller.libraryRow(id: item.id)?.kind ?? .unknown) != .unknown
    let label = reapplies ? L("Reapply wallpaper") : L("Apply wallpaper")
    Button {
      let id = item.id
      if reapplies {
        controller.launch(PanelActionCoordinator.key("reapplyWallpaper", id: id)) { [controller] in
          try await controller.reapply(id)
        }
      } else {
        controller.launch(PanelActionCoordinator.key("activate", id: id)) { [controller] in
          try await controller.activate(id)
        }
      }
    } label: {
      Image(systemName: reapplies ? "arrow.clockwise" : "play.fill")
        .font(.system(size: 14, weight: .bold))
        .foregroundStyle(theme.accent.onPrimary.color)
        .frame(width: 38, height: 38)
        .background(theme.accent.primary.color, in: Circle())
        .shadow(color: .black.opacity(0.3), radius: 4, y: 1)
    }
    .buttonStyle(.plain)
    .disabled(!(canActivate && target.canShowWallpaper))
    .help(label)
    .accessibilityLabel(Text(verbatim: label))
    .accessibilityIdentifier("workshop-inspector-apply")
  }
}

// MARK: - Actions

/// The buttons the inspector offers for an item's download, in order. One request or job decides
/// them (`WorkshopItemDownload.action`); this only names what each case draws.
enum WorkshopInspectorButton: Equatable {
  case openCollection
  case resume
  case continueSetup
  case finishSignIn
  /// The button that reads where the download is (`label`) and opens the Downloads list.
  case progress(label: String)
  case cancel
  case removeFromQueue
  case download
  case downloadAgain
  case downloadAndApply

  /// The key the button's action runs under, which the button is disabled on while that action is
  /// pending, so a second click visibly does nothing; nil for the buttons that only open the
  /// dialog or the Downloads list.
  func actionKey(forItem id: String) -> String? {
    switch self {
    case .openCollection: PanelActionCoordinator.key("workshopCollection", id: id)
    case .resume: PanelActionCoordinator.key("downloadResume", id: id)
    case .cancel, .removeFromQueue: PanelActionCoordinator.key("downloadCancel", id: id)
    case .download, .downloadAgain, .downloadAndApply:
      PanelActionCoordinator.key("requestDownload", id: id)
    case .continueSetup, .finishSignIn, .progress: nil
    }
  }

  /// The buttons for an item that is not installed.
  static func buttons(for download: WorkshopItemDownload) -> [WorkshopInspectorButton] {
    switch download.action {
    case .openCollection: [.openCollection]
    case .resume: [.resume]
    case .continueSetup: [.continueSetup]
    case .finishSignIn: [.finishSignIn]
    case .inProgress(let label, let isQueued):
      [.progress(label: label), isQueued ? .removeFromQueue : .cancel]
    case .download(let again, _):
      [again ? .downloadAgain : .download] + (download.offersDownloadAndApply ? [.downloadAndApply] : [])
    }
  }
}

/// The buttons: what to do about the download, and the links.
private struct ItemActions: View {
  let item: WorkshopItem
  let download: WorkshopItemDownload

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let model = controller.workshopBrowser
    let downloads = controller.downloads
    VStack(spacing: 8) {
      if !download.isInstalled { downloadActions(model: model, downloads: downloads) }
      if download.isInstalled, controller.previewAvailable, item.canRunOnMac {
        Button {
          let id = item.id
          controller.launch(PanelActionCoordinator.key("previewWallpaper", id: id)) { [controller] in
            try await controller.previewWallpaper(id)
          }
        } label: {
          Label("Preview wallpaper", systemImage: "eye")
        }
        .buttonStyle(.panelSecondary(size: .regular, expands: true))
        .help(L("Open a live preview without changing your desktop"))
      }
      HStack(spacing: 8) {
        Button {
          model.viewOnSteam(item)
        } label: {
          Label("View on Steam Workshop", systemImage: "arrow.up.right.square")
        }
        .buttonStyle(.panelSecondary(size: .regular, expands: true))
        if let share = controller.wallpaperShare(item.id) {
          ShareLink(
            item: share.url, subject: Text(verbatim: share.subject),
            message: Text(verbatim: share.message)
          ) {
            Image(systemName: "square.and.arrow.up")
          }
          .buttonStyle(.panelSecondary(size: .regular))
          .help(L("Share…"))
          .accessibilityLabel(L("Share…"))
        }
      }
    }
  }

  @ViewBuilder
  private func downloadActions(model: WorkshopBrowserModel, downloads: DownloadsModel) -> some View {
    ForEach(Array(WorkshopInspectorButton.buttons(for: download).enumerated()), id: \.offset) {
      _, button in
      actionButton(button, model: model, downloads: downloads)
        .disabled(button.actionKey(forItem: item.id).map(controller.isBusy) ?? false)
    }
  }

  @ViewBuilder
  private func actionButton(
    _ button: WorkshopInspectorButton, model: WorkshopBrowserModel, downloads: DownloadsModel
  ) -> some View {
    switch button {
    case .openCollection:
      primary(systemImage: "square.stack") { Text("Open collection") } action: {
        model.openCollection(item)
      }
    case .resume:
      primary(systemImage: "play.fill") { Text("Resume download") } action: {
        downloads.perform(.resume, forItem: item.id)
      }
    case .continueSetup:
      primary(systemImage: "checkmark.shield") { Text("Continue setup") } action: {
        downloads.openDialog(for: item.id)
      }
    case .finishSignIn:
      primary(systemImage: "checkmark.shield") { Text("Finish sign-in") } action: {
        downloads.openDialog(for: item.id)
      }
    case .progress(let label):
      // The button reads where the download is and opens the Downloads list.
      primary(systemImage: "arrow.down.circle") { Text(verbatim: label) } action: {
        downloads.showDownloads()
      }
    case .cancel:
      secondary { Text("Cancel") } action: { downloads.perform(.cancel, forItem: item.id) }
    case .removeFromQueue:
      secondary { Text("Remove from queue") } action: {
        downloads.perform(.cancel, forItem: item.id)
      }
    case .download:
      primary(systemImage: "arrow.down.circle") { Text("Download") } action: {
        downloads.requestDownload(item)
      }
    case .downloadAgain:
      primary(systemImage: "arrow.down.circle") { Text("Download again") } action: {
        downloads.requestDownload(item)
      }
    case .downloadAndApply:
      secondary(systemImage: "play.fill") { Text("Download and apply") } action: {
        downloads.requestDownload(item, apply: true)
      }
    }
  }

  /// A neutral button across the inspector's width.
  private func secondary<Title: View>(
    systemImage: String? = nil, @ViewBuilder title: () -> Title, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Label {
        title()
      } icon: {
        if let systemImage { Image(systemName: systemImage) }
      }
      .labelStyle(.titleAndIcon)
    }
    .buttonStyle(.panelSecondary(size: .regular, expands: true))
  }

  /// The accent-filled button across the inspector's width.
  private func primary<Title: View>(
    systemImage: String, @ViewBuilder title: () -> Title, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Label {
        title()
      } icon: {
        Image(systemName: systemImage)
      }
    }
    .buttonStyle(.panelPrimary(size: .regular, expands: true))
  }
}

// MARK: - Notes

/// Everything the inspector says besides the item itself: how the download is going, what it waits
/// for, why a wallpaper that arrived was not applied, why it failed, the compatibility of its type,
/// and the links to the Downloads list and the library.
private struct DownloadNotes: View {
  let item: WorkshopItem
  let download: WorkshopItemDownload

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let downloads = controller.downloads
    let isInstalled = download.isInstalled
    VStack(alignment: .leading, spacing: 10) {
      if download.showsProgress {
        VStack(alignment: .leading, spacing: 4) {
          // Determinate once the job has a figure, a sweeping bar until then.
          ProgressView(value: download.progress)
            .progressViewStyle(.linear)
            .accessibilityLabel(Text(verbatim: L("\(item.title) download progress")))
          Text(verbatim: download.statusLine)
            .font(.system(size: 11.5))
            .foregroundStyle(theme.surface.muted.color)
            .textSelection(.enabled)
            .accessibilityAddTraits(.updatesFrequently)
        }
      }
      if let hint = download.stageHint {
        Text(verbatim: hint).noteStyle(theme)
      }
      if download.appliesOnArrival {
        Text("Will apply when the download finishes.").noteStyle(theme)
      }
      if let note = download.applyNote {
        DownloadNotice(kind: .info, text: note)
      }
      if isInstalled, let notice = controller.workshopUpdateNotice(for: item.id) {
        UpdateNotice(item: item, notice: notice)
      }
      // What keeps a scene from playing comes before any failure: getting the resources is the
      // way forward, where a failure's report link is not.
      if sceneResourcesMissing { sceneResources }
      failure
      if isInstalled, download.hasFinishedDownload { showInLibrary }
      if download.showsInDownloads {
        Button("Show in downloads") { downloads.showDownloads() }
          .buttonStyle(.panelLink)
          .font(.system(size: 12))
      }
      if let compatibility = compatibilityNote {
        Text(verbatim: compatibility).noteStyle(theme)
      }
      if isInstalled { installedLinks }
      if isInstalled, !download.hasFinishedDownload { showInLibrary }
    }
  }

  // MARK: Shared scene resources

  /// A scene cannot play until Wallpaper Engine's shared resources are installed.
  private var sceneResourcesMissing: Bool {
    item.kind == .scene && !controller.workshop.sceneAssetsReady
  }

  /// The one-time setup of the shared resources, as the notice's own button, or their download
  /// while it is under way.
  private var sceneResources: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Image(systemName: "exclamationmark.circle.fill")
        .foregroundStyle(theme.surface.warning.color)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 8) {
        Text("Shared scene resources are required before playback.")
        if controller.sceneResourcesArePending {
          Button("Show in downloads") { controller.downloads.showDownloads() }
            .buttonStyle(.panelLink)
        } else {
          Button {
            controller.downloads.requestSceneAssets()
          } label: {
            Label("Get shared resources", systemImage: "shippingbox")
          }
          .buttonStyle(.panelPrimary(size: .compact))
          .disabled(controller.isBusy(PanelActionCoordinator.key("requestDownload", id: "")))
        }
      }
      .font(.system(size: 12))
    }
    .padding(10)
    .background(
      theme.surface.warning.color.opacity(0.1),
      in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .accessibilityElement(children: .contain)
  }

  // MARK: Failure and reports

  /// What a failed download said, or what the last attempt to apply an installed copy said, with the
  /// report prefilled with it; without a failure an installed wallpaper that can run offers a plain
  /// report link. A scene waiting for the shared resources offers no report for applying it: the
  /// notice above is the way forward.
  @ViewBuilder
  private var failure: some View {
    let applyFailure = download.isInstalled ? controller.activationFailures[item.id] : nil
    if let message = download.failure ?? applyFailure {
      VStack(alignment: .leading, spacing: 6) {
        DownloadNotice(kind: .error, text: message)
        if download.failure != nil || !sceneResourcesMissing, let url = reportURL(failure: message) {
          Button {
            ExternalLink.open(url)
          } label: {
            Label("Report this problem on GitHub", systemImage: "exclamationmark.bubble")
              .labelStyle(.panelLinkRow)
          }
          .buttonStyle(.panelLink)
          .font(.system(size: 12))
        }
      }
    }
  }

  private func reportURL(failure: String) -> URL? {
    download.isInstalled
      ? controller.issueReportURL(for: item.id, failure: failure)
      : controller.workshopIssueReportURL(for: item, failure: failure)
  }

  @ViewBuilder
  private var installedLinks: some View {
    let hasFailure = controller.activationFailures[item.id] != nil
    if !hasFailure, !sceneResourcesMissing, item.canRunOnMac, let url = controller.issueReportURL(for: item.id) {
      Button {
        ExternalLink.open(url)
      } label: {
        Label("Not working? Report on GitHub", systemImage: "exclamationmark.bubble")
          .labelStyle(.panelLinkRow)
      }
      .buttonStyle(.panelLink)
      .font(.system(size: 12))
    }
    if controller.canReinstallWorkshopItem(item) {
      Button {
        let id = item.id
        controller.launch(PanelActionCoordinator.key("workshopReinstall", id: id)) { [controller] in
          try await controller.reinstallWorkshopItem(id: id)
        }
      } label: {
        Label("Reinstall from Workshop…", systemImage: "arrow.clockwise")
          .labelStyle(.panelLinkRow)
      }
      .buttonStyle(.panelLink)
      .font(.system(size: 12))
    }
  }

  private var showInLibrary: some View {
    Button {
      let id = item.id
      controller.launch(PanelActionCoordinator.key("showInstalled", id: id)) { [controller] in
        try await controller.showInstalled(id)
      }
    } label: {
      Label("Show in library", systemImage: "photo")
        .labelStyle(.panelLinkRow)
    }
    .buttonStyle(.panelLink)
    .font(.system(size: 12))
  }

  // MARK: Compatibility

  /// What to expect of the item's type, in a line; a type that is not named says nothing.
  @MainActor
  private var compatibilityNote: String? {
    if item.isCollection {
      return L(
        "A collection is a list of Workshop items put together by its author. Open it to see and download them."
      )
    }
    switch item.kind {
    case .scene: return L("Scene renderer is experimental.")
    case .video: return L("Playback depends on the video codec.")
    case .web:
      return L(
        "Runs in a built-in web view. Mouse input and audio response reach the page; keyboard input does not."
      )
    case .application: return L("Application wallpapers cannot run on macOS.")
    case .all: return nil
    }
  }
}

/// An installed Workshop wallpaper whose author changed it since: what changed and the one button
/// that downloads the new version.
private struct UpdateNotice: View {
  let item: WorkshopItem
  let notice: WorkshopUpdateNotice

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let downloads = controller.downloads
    VStack(alignment: .leading, spacing: 8) {
      Text(verbatim: notice.message())
        .font(.system(size: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityAddTraits(.updatesFrequently)
      switch notice.action {
      case .showInDownloads:
        Button("Show in downloads") { downloads.showDownloads() }
          .buttonStyle(.panelLink)
      case .continueSetup:
        Button {
          downloads.openDialog(for: item.id)
        } label: {
          Label("Continue setup", systemImage: "checkmark.shield")
        }
        .buttonStyle(.panelPrimary(size: .compact))
      case .update:
        Button {
          let id = item.id
          controller.launch(PanelActionCoordinator.key("workshopUpdate", id: id)) { [controller] in
            try await controller.updateWorkshopItem(id: id)
          }
        } label: {
          Label("Update", systemImage: "arrow.down.circle")
        }
        .buttonStyle(.panelPrimary(size: .compact))
        .disabled(controller.isBusy(PanelActionCoordinator.key("workshopUpdate", id: item.id)))
      }
    }
    .padding(10)
    .background(
      theme.accent.accent.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
  }
}

private extension Text {
  /// A small muted line, as the inspector's hints are.
  func noteStyle(_ theme: PanelTheme) -> some View {
    font(.system(size: 11.5))
      .foregroundStyle(theme.surface.muted.color)
      .frame(maxWidth: .infinity, alignment: .leading)
      .textSelection(.enabled)
  }
}
