import SwiftUI

/// The buttons the inspector offers for an item's library copy or download.
enum WorkshopInspectorButton: Equatable {
  case moveToTrash
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
    case .moveToTrash: PanelActionCoordinator.key("delete", id: id)
    case .openCollection: PanelActionCoordinator.key("workshopCollection", id: id)
    case .resume: DownloadRowAction.resume.key(.steam, id: id)
    case .cancel, .removeFromQueue: DownloadRowAction.cancel.key(.steam, id: id)
    case .download, .downloadAgain, .downloadAndApply:
      PanelActionCoordinator.key("requestDownload", id: id)
    case .continueSetup, .finishSignIn, .progress: nil
    }
  }

  /// Installed wallpapers can be removed; collections are always opened.
  static func buttons(for download: WorkshopItemDownload) -> [WorkshopInspectorButton] {
    if download.action == .openCollection { return [.openCollection] }
    if download.isInstalled { return [.moveToTrash] }
    return switch download.action {
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
struct WorkshopItemActions: View {
  let item: WorkshopItem
  let download: WorkshopItemDownload

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let model = controller.workshopBrowser
    let downloads = controller.downloads
    VStack(spacing: 8) {
      downloadActions(model: model, downloads: downloads)
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
      if controller.workshop.steamWebSession != nil, !item.isCollection { subscription }
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

  /// **Subscribe on Steam** or **Unsubscribe on Steam**, for the signed-in Steam Community account.
  private var subscription: some View {
    let subscribed = controller.workshop.subscribedIDs.contains(item.id)
    let key = PanelActionCoordinator.key("workshopSubscription", id: item.id)
    return Button {
      let item = item
      controller.launch(key) { [controller] in
        try await controller.setWorkshopSubscribed(!subscribed, item: item)
      }
    } label: {
      if subscribed {
        Label("Unsubscribe on Steam", systemImage: "bookmark.slash")
      } else {
        Label("Subscribe on Steam", systemImage: "bookmark")
      }
    }
    .buttonStyle(.panelSecondary(size: .regular, expands: true))
    .disabled(controller.isBusy(key))
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
    case .moveToTrash:
      Button(role: .destructive) {
        let id = item.id
        controller.launch(PanelActionCoordinator.key("delete", id: id)) { [controller] in
          try await controller.delete(id)
        }
      } label: {
        Label("Move to Trash", systemImage: "trash")
      }
      .buttonStyle(.panelSecondary(size: .regular, expands: true))
      .accessibilityIdentifier("workshop.moveToTrash")
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
