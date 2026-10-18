import SwiftUI

/// What the inspector says about the wallpaper under its header: why a download was not applied, an
/// update, the shared resources a scene still needs, the last failure, what each display's host
/// reports, the wallpaper's type and a way to report a problem.
struct InspectorNotices: View {
  let row: LibraryRow

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let id = row.id
    let failure = controller.activationFailures[id]
    let hosts = controller.hostStates(for: id)
    let updateNotice = controller.workshopUpdateNotice(for: id)
    let note = controller.workshopApplyNote(for: id)
    let request = controller.downloadRequestRow(for: id)
    let job = controller.steamDownloadRow(for: id)
    // An update or a reinstall that will take the wallpaper's place says where it waits and whether
    // it applies itself when it arrives.
    let appliesOnArrival =
      request.map(\.appliesOnArrival) ?? (job?.isPending == true ? job?.appliesOnArrival : nil)
    VStack(alignment: .leading, spacing: 10) {
      if let note {
        InspectorNotice {
          Text(verbatim: note).textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
        .announcing(note)
      }
      if let updateNotice {
        UpdateNoticeView(id: id, notice: updateNotice)
      }
      if let request {
        InspectorNote(verbatim: request.stage.hint)
      }
      if appliesOnArrival == true {
        InspectorNote("Will apply when the download finishes.")
      }
      // Missing resources come before any failure: that is what keeps the scene from playing, and
      // getting them is the way forward, where a failure's report link is not.
      if controller.workshopSceneAssetsAreMissing(for: row) {
        SceneResourcesNotice()
      }
      if let failure {
        FailureNoticeView(row: row, failure: failure)
      }
      ForEach(hosts) { host in
        HostStatusView(row: host)
      }
      if controller.offersShowInDownloads(for: id) {
        Button("Show in downloads") { controller.downloads.showDownloads() }
          .buttonStyle(.inspectorLink)
      }
      TypeNoteView(row: row)
    }
  }
}

// MARK: - Shared scene resources

/// A scene cannot play until Wallpaper Engine's shared resources are installed: the one-time setup,
/// offered as the notice's own button, or their download when it is already under way.
struct SceneResourcesNotice: View {
  @Environment(PanelController.self) private var controller

  var body: some View {
    InspectorNotice(tone: .warning) {
      Text("Shared scene resources are required before playback.")
      if controller.sceneResourcesArePending {
        Button("Show in downloads") { controller.downloads.showDownloads() }
          .buttonStyle(.inspectorLink)
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
    .accessibilityElement(children: .contain)
  }
}

// MARK: - Update

struct UpdateNoticeView: View {
  let id: String
  let notice: WorkshopUpdateNotice

  @Environment(PanelController.self) private var controller

  var body: some View {
    let message = notice.message()
    let updateKey = PanelActionCoordinator.key("workshopUpdate", id: id)
    InspectorNotice(systemImage: "arrow.down.circle.fill") {
      Text(verbatim: message).textSelection(.enabled)
      switch notice.action {
      case .showInDownloads:
        Button("Show in downloads") { controller.downloads.showDownloads() }
          .buttonStyle(.inspectorLink)
      case .continueSetup:
        Button {
          controller.downloads.openDialog(for: controller.downloadRequestRow(for: id)?.id ?? id)
        } label: {
          Label("Continue setup", systemImage: "checkmark.shield")
        }
        .buttonStyle(.panelPrimary(size: .compact))
      case .update:
        Button {
          controller.launch(updateKey) { try await controller.updateWorkshopItem(id: id) }
        } label: {
          Label("Update", systemImage: "arrow.down.circle")
        }
        .buttonStyle(.panelPrimary(size: .compact))
        .disabled(controller.isBusy(updateKey))
      }
    }
    .accessibilityElement(children: .contain)
    .announcing(message)
  }
}

// MARK: - Failure

struct FailureNoticeView: View {
  let row: LibraryRow
  let failure: String

  @Environment(PanelController.self) private var controller

  var body: some View {
    InspectorNotice(tone: .error) {
      Text(verbatim: failure).textSelection(.enabled)
      if case .failure = controller.inspectorIssueReport(for: row),
        let url = controller.issueReportURL(for: row.id, failure: failure)
      {
        Button {
          ExternalLink.open(url)
        } label: {
          Label("Report this problem on GitHub", systemImage: "exclamationmark.bubble")
        }
        .buttonStyle(.inspectorLink)
      }
    }
    .accessibilityElement(children: .contain)
  }
}

// MARK: - Host status

/// What the host reports for the wallpaper on one display: loading, ready, or failed with the
/// reason in the host's own words (text, never markup) and a Retry where one is possible.
struct HostStatusView: View {
  let row: HostStateRow

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let headline = InspectorWording.hostStatus(row)
    let retryKey = PanelActionCoordinator.key(
      "retryHostWallpaper", id: row.wallpaperID, displayID: String(row.displayID))
    InspectorNotice(
      tone: row.phase == .failed ? .error : .info,
      systemImage: row.phase == .ready ? "checkmark.circle.fill" : row.phase == .failed ? nil : "hourglass"
    ) {
      Text(verbatim: headline).fontWeight(.semibold).textSelection(.enabled)
      if let message = row.message, !message.isEmpty {
        Text(verbatim: message).textSelection(.enabled)
      }
      if row.canRetry {
        Button {
          controller.launch(retryKey) {
            try await controller.retryHostWallpaper(row.wallpaperID, on: row.displayID)
          }
        } label: {
          Label("Retry wallpaper", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.inspectorLink)
        .disabled(controller.isBusy(retryKey))
      }
    }
    .accessibilityElement(children: .contain)
    .announcing(headline)
  }
}

// MARK: - The wallpaper's type

/// The sentence about the wallpaper's type, the pixiv link of a saved illustration, and the plain
/// problem-report link.
struct TypeNoteView: View {
  let row: LibraryRow

  @Environment(PanelController.self) private var controller

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      note
      if let artwork = InspectorPolicy.pixivArtworkID(of: row.id).flatMap(ExternalLink.pixivArtwork(id:)) {
        Button {
          ExternalLink.open(artwork)
        } label: {
          Label("View on pixiv", systemImage: "arrow.up.right.square")
        }
        .buttonStyle(.inspectorLink)
      }
      // After a failure the report travels with the notice above; otherwise this is where someone
      // checking a problem is reading. A wallpaper that cannot run has nothing to report but its
      // type, which the sentence above says.
      if controller.inspectorIssueReport(for: row) == .plain,
        let url = controller.issueReportURL(for: row.id)
      {
        Button {
          ExternalLink.open(url)
        } label: {
          Label("Not working? Report on GitHub", systemImage: "exclamationmark.bubble")
        }
        .buttonStyle(.inspectorLink)
      }
    }
  }

  @ViewBuilder
  private var note: some View {
    switch InspectorPolicy.kindNote(for: row) {
    case .pixivStill:
      InspectorNote("A still illustration saved from pixiv. Choose how it fits the screen under Image fit.")
    case .importedStill:
      InspectorNote("A still image imported from your Mac. Choose how it fits the screen under Image fit.")
    case .scene: InspectorNote("Scene renderer is experimental.")
    case .video: InspectorNote("Playback depends on the video codec.")
    case .web:
      InspectorNote(
        "Runs in a built-in web view. Mouse input and audio response reach the page; keyboard input does not."
      )
    case .unsupported: InspectorNote("This wallpaper type is not supported.")
    }
  }
}
