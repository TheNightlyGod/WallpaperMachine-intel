import SwiftUI

/// The Downloads list that hangs under the toolbar button: the requests that wait on the person, the
/// downloads that run or wait for a slot, those that stopped and need a decision, and, on request,
/// the ones that finished.
///
/// Steam's jobs and pixiv's saves are one list. Each row offers what that download can do; closing
/// the popover never stops one.
struct DownloadsPopover: View {
  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  /// A queue to list instead of the controller's, for a test that renders states the stores would
  /// need live downloads to reach.
  private let fixedQueue: DownloadQueue?

  init(queue: DownloadQueue? = nil) { fixedQueue = queue }

  var body: some View {
    let model = controller.downloads
    let queue = fixedQueue ?? controller.downloadQueue
    let entries = queue.entries(showingCompleted: model.showsCompleted)
    VStack(spacing: 0) {
      header(queue)
      Divider()
      if entries.isEmpty {
        Text(verbatim: queue.emptyMessage)
          .font(.system(size: 12.5))
          .foregroundStyle(theme.surface.muted.color)
          .multilineTextAlignment(.center)
          .frame(maxWidth: .infinity)
          .padding(24)
      } else {
        ScrollView {
          LazyVStack(spacing: 0) {
            // One ForEach: a job that resumes, pauses or fails keeps its row.
            ForEach(entries) { entry in
              switch entry {
              case .request(let request): DownloadsPopoverRequestRow(request: request)
              case .job(let row): DownloadsPopoverJobRow(row: row)
              }
            }
          }
        }
        .frame(maxHeight: 360)
      }
      Divider()
      footer(queue)
    }
    .frame(width: 360)
    .foregroundStyle(theme.surface.text.color)
  }

  // MARK: Header and footer

  private func header(_ queue: DownloadQueue) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("Downloads")
        .font(.system(size: 13, weight: .semibold))
        .accessibilityAddTraits(.isHeader)
      // The batch in one line: how many, how far, how fast, how long.
      Text(verbatim: queue.summary)
        .font(.system(size: 11.5))
        .foregroundStyle(theme.surface.muted.color)
        .lineLimit(2)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
  }

  private func footer(_ queue: DownloadQueue) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(verbatim: queue.note)
        .font(.system(size: 11))
        .foregroundStyle(theme.surface.muted.color)
        .frame(maxWidth: .infinity, alignment: .leading)
      DownloadsPopoverActions(
        completedCount: queue.succeeded.count, canClearFinished: queue.canClearFinished)
    }
    .padding(12)
  }
}

/// The footer's controls: Show or Hide completed, Show download logs, and Clear finished.
///
/// None of them ever wraps or truncates its label. They share one row when it has room, else the
/// links keep a row and Clear finished takes the next, else each link has a row of its own: the
/// first arrangement that fits the popover's width in the panel's language is the one drawn.
struct DownloadsPopoverActions: View {
  enum Arrangement: CaseIterable {
    case oneRow, linksThenClear, stacked
  }

  /// How many finished downloads there are to show or hide; none offers no toggle.
  let completedCount: Int
  let canClearFinished: Bool
  /// One arrangement to draw instead of the first that fits, for a test that measures each.
  var arrangement: Arrangement?

  @Environment(PanelController.self) private var controller

  var body: some View {
    Group {
      if let arrangement {
        arranged(arrangement)
      } else {
        ViewThatFits(in: .horizontal) {
          ForEach(Arrangement.allCases, id: \.self) { arranged($0) }
        }
      }
    }
    .font(.system(size: 12))
  }

  @ViewBuilder
  private func arranged(_ arrangement: Arrangement) -> some View {
    switch arrangement {
    case .oneRow:
      HStack(spacing: 12) {
        links
        Spacer(minLength: 8)
        clear
      }
    case .linksThenClear:
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 12) { links }
        clearRow
      }
    case .stacked:
      VStack(alignment: .leading, spacing: 8) {
        links
        clearRow
      }
    }
  }

  @ViewBuilder
  private var links: some View {
    let model = controller.downloads
    if completedCount > 0 {
      // Two literals, so each is looked up as the catalog key it is.
      Group {
        if model.showsCompleted {
          Button("Hide completed") { model.showsCompleted = false }
        } else {
          Button(L("Show completed (\(completedCount))")) { model.showsCompleted = true }
        }
      }
      .buttonStyle(.panelLink)
      .fixedSize()
    }
    Button { model.showLogs() } label: {
      Label("Show download logs", systemImage: "folder")
    }
    .buttonStyle(.panelLink)
    .fixedSize()
  }

  @ViewBuilder
  private var clear: some View {
    if canClearFinished {
      Button("Clear finished") { controller.downloads.clearFinished() }
        .buttonStyle(.panelSecondary(size: .compact))
        .fixedSize()
    }
  }

  @ViewBuilder
  private var clearRow: some View {
    if canClearFinished {
      HStack {
        Spacer(minLength: 0)
        clear
      }
    }
  }
}

// MARK: - Rows

/// The picture, title and lines of one entry, with its actions beneath.
private struct RowFrame<Content: View>: View {
  let image: PanelImageSource?
  let title: String
  var needsAttention = false
  @ViewBuilder var content: Content

  @Environment(\.panelTheme) private var theme

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      PanelImage(source: image, pointSize: 44)
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(theme.surface.divider.color, lineWidth: 0.5)
        }
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        // Titles come from the Workshop and from pixiv: never a catalog key.
        Text(verbatim: title)
          .font(.system(size: 12.5, weight: .semibold))
          .lineLimit(2)
          .frame(maxWidth: .infinity, alignment: .leading)
          .textSelection(.enabled)
        content
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(needsAttention ? theme.accent.accent.color.opacity(0.07) : Color.clear)
    .overlay(alignment: .bottom) {
      Rectangle().fill(theme.surface.divider.color).frame(height: 0.5).padding(.leading, 66)
    }
    .accessibilityElement(children: .contain)
  }
}

private extension View {
  func statusLine(_ color: Color) -> some View {
    font(.system(size: 11.5)).foregroundStyle(color).frame(maxWidth: .infinity, alignment: .leading)
      .textSelection(.enabled)
  }
}

/// A request that waits for the person: SteamCMD, the account or the consent.
struct DownloadsPopoverRequestRow: View {
  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme
  let request: DownloadRequestRow

  var body: some View {
    let model = controller.downloads
    RowFrame(image: request.image, title: request.title, needsAttention: true) {
      Text(verbatim: request.isPaused ? L("Download paused") : request.stage.hint)
        .statusLine(theme.surface.muted.color)
      HStack(spacing: 8) {
        if request.isPaused {
          Button {
            controller.launch(PanelActionCoordinator.key("downloadResume", id: request.id)) {
              try await controller.resumeDownload(id: request.id)
            }
          } label: {
            Label("Resume download", systemImage: "play.fill")
          }
          .buttonStyle(.panelPrimary(size: .compact))
        } else {
          Button {
            model.openDialog(for: request.id)
          } label: {
            Label("Continue setup", systemImage: "checkmark.shield")
          }
          .buttonStyle(.panelPrimary(size: .compact))
        }
        Spacer(minLength: 0)
        Button {
          model.removeRequest(request)
        } label: {
          Image(systemName: "xmark")
            .font(.system(size: 10.5, weight: .semibold))
            .frame(width: 22, height: 22)
        }
        .buttonStyle(.borderless)
        .help(L("Remove \(request.title) from downloads"))
        .accessibilityLabel(Text(verbatim: L("Remove \(request.title) from downloads")))
      }
    }
  }
}

/// One download: Steam's or pixiv's.
struct DownloadsPopoverJobRow: View {
  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme
  @Environment(\.locale) private var locale
  let row: DownloadRow

  var body: some View {
    let model = controller.downloads
    let running = row.isRunning
    let review = row.isUnresolved
    let setupReady = controller.steamSetup.isReady
    RowFrame(
      image: row.image, title: row.title, needsAttention: row.needsAuthentication || review
    ) {
      Text(verbatim: Self.statusLine(for: row, locale: locale))
        .statusLine(theme.surface.muted.color)
        .accessibilityAddTraits(running ? .updatesFrequently : [])
      if running {
        // Determinate once the job has a figure, a sweeping bar until then.
        ProgressView(value: row.clampedProgress)
          .progressViewStyle(.linear)
          .accessibilityLabel(Text(verbatim: L("\(row.title) download progress")))
      }
      if let error = row.errorMessage, !error.isEmpty {
        DownloadNotice(kind: .error, text: error)
      }
      if let warning = row.warning, !warning.isEmpty {
        DownloadNotice(kind: .warning, text: warning)
      }
      actions(model: model, setupReady: setupReady, review: review)
    }
  }

  /// What the row says: the job's own sentence, and while it runs the amounts it has moved ("42% ·
  /// 860 B of 2 KB · Network speed: 600 KB/s · 4 min left", each part only when it is known).
  @MainActor
  static func statusLine(for row: DownloadRow, locale: Locale) -> String {
    guard row.isRunning else { return row.status }
    let transfer = TransferFormat.transfer(row.transferProgress, locale: locale)
    return transfer.isEmpty ? row.status : "\(row.status) · \(transfer)"
  }

  private func actions(model: DownloadsModel, setupReady: Bool, review: Bool) -> some View {
    let installed = controller.mediaLibraryContains(row.id)
    return TagFlow(spacing: 8) {
      if row.needsAuthentication {
        Button {
          model.openDialog(for: row.id)
        } label: {
          Label("Finish sign-in", systemImage: "checkmark.shield")
        }
        .buttonStyle(.panelPrimary(size: .compact))
      }
      if row.canResume {
        Button {
          model.resume(row)
        } label: {
          Label("Resume download", systemImage: "play.fill")
        }
        .buttonStyle(.panelPrimary(size: .compact))
        .disabled(controller.isBusy(DownloadsModel.key("resume", row: row)))
      } else if review && row.canRetry {
        Button {
          model.retry(row)
        } label: {
          Label("Try again", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.panelPrimary(size: .compact))
        // A Steam retry needs SteamCMD; pixiv's does not.
        .disabled(row.source == .steam && !setupReady)
      }
      if row.canPause {
        Button("Pause download") { model.pause(row) }
          .buttonStyle(.panelSecondary(size: .compact))
      }
      if row.canCancel {
        Group {
          // Two literals, so each is looked up as the catalog key it is.
          if row.isQueued {
            Button("Remove from queue") { model.cancel(row) }
          } else {
            Button("Cancel") { model.cancel(row) }
          }
        }
        .buttonStyle(.panelSecondary(size: .compact))
      }
      if review && row.canRetry && row.source == .steam && !setupReady {
        Text(verbatim: WorkshopDownloadStage.setup.hint)
          .font(.system(size: 11.5))
          .foregroundStyle(theme.surface.muted.color)
      }
      if installed {
        Button {
          controller.launch(PanelActionCoordinator.key("showInstalled", id: row.id)) {
            try await controller.showInstalled(row.id)
          }
        } label: {
          Label("Show in library", systemImage: "photo")
        }
        .buttonStyle(.panelLink)
        Button {
          controller.launch(PanelActionCoordinator.key("reveal", id: row.id)) {
            try await controller.reveal(row.id)
          }
        } label: {
          Label("Show in Finder", systemImage: "folder")
        }
        .buttonStyle(.panelLink)
      }
    }
    .font(.system(size: 12))
  }
}
