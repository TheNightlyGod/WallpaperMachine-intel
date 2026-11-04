import SwiftUI

/// Everything the inspector says besides the item itself: how the download is going, what it waits
/// for, why a wallpaper that arrived was not applied, why it failed, the compatibility of its type,
/// and the links to the Downloads list and the library.
struct WorkshopDownloadNotes: View {
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
      if sceneResourcesMissing { SceneResourcesNotice(linkStyle: .panelLink) }
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
    controller.workshopSceneAssetsAreMissing(for: item.kind)
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
