import SwiftUI

/// The inspector beside the pixiv page: the selected work's picture, title, artist and tags, a
/// stepper through its pages, and what to do with the page on show: download it, pause or cancel
/// the download, or apply it once it is in the library.
struct PixivInspector: View {
  @Environment(PanelController.self) private var controller

  var body: some View {
    if let selection = controller.pixivSelection {
      // Keyed by the work, so a new selection starts at the top with its own picture.
      PixivInspectorDetail(selection: selection)
        .id(selection.work.id)
    } else {
      PanelEmptyState(
        "Select an illustration", systemImage: "paintpalette",
        description: "Its preview, pages and download appear here.")
    }
  }
}

private struct PixivInspectorDetail: View {
  let selection: PixivSelection

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  private var work: PixivWork { selection.work }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        artwork
        heading
        pages
        actions
        progress
        if let failure = selection.failure {
          PixivNotice(message: failure, style: .failure)
        }
        if !work.tags.isEmpty { tags }
        links
        Text(
          "Saved to your library as a still wallpaper that applies like any other. The artwork belongs to its artist."
        )
        .font(.caption)
        .foregroundStyle(theme.surface.muted.color)
        .textSelection(.enabled)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(16)
    }
    .accessibilityIdentifier("pixiv-inspector")
  }

  // MARK: Picture and heading

  /// The page whole, in a 16:10 well, never cropped.
  private var artwork: some View {
    ZStack {
      theme.surface.mediaWell.color
      PanelImage(
        source: selection.preview ?? selection.thumbnail, pointSize: 340, contentMode: .fit)
    }
    .aspectRatio(16.0 / 10.0, contentMode: .fit)
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .strokeBorder(theme.surface.divider.color, lineWidth: 0.5)
    }
    .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
    .accessibilityHidden(true)
  }

  private var heading: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(verbatim: work.displayTitle)
        .font(.system(size: 17, weight: .bold))
        .foregroundStyle(theme.surface.text.color)
        .textSelection(.enabled)
        .accessibilityAddTraits(.isHeader)
      if !work.authorName.isEmpty {
        if let profile = work.authorProfileURL {
          Button {
            ExternalLink.open(profile)
          } label: {
            Text(verbatim: work.authorName)
          }
          .buttonStyle(.link)
          .help(L("View on pixiv"))
        } else {
          Text(verbatim: work.authorName)
            .font(.system(size: 13))
            .foregroundStyle(theme.surface.muted.color)
            .textSelection(.enabled)
        }
      }
      let meta = PixivMeta.parts(selection)
      if !meta.isEmpty {
        Text(verbatim: meta.joined(separator: " · "))
          .font(.system(size: 12))
          .foregroundStyle(theme.surface.muted.color)
          .textSelection(.enabled)
      }
    }
  }

  // MARK: Pages

  /// The stepper and "Loading pages…" belong to a work of several pages. A page list that could
  /// not be read is said for every work: a members-only work of one page fails the same way, and
  /// without the notice its Download would fail later with no word of why or of signing in.
  @ViewBuilder
  private var pages: some View {
    let isMultiPage = selection.pageCount > 1
    if isMultiPage || pagesFailure != nil {
      VStack(alignment: .leading, spacing: 8) {
        if isMultiPage {
          PixivPageStepper(selection: selection)
          if selection.pages == .loading {
            Text("Loading pages…").font(.caption).foregroundStyle(theme.surface.muted.color)
          }
        }
        if let failure = pagesFailure {
          PixivNotice(message: failure, style: .warning) {
            Button("Try again") {
              controller.launch("pixivRetryPages") { try await controller.pixivRetryPages() }
            }
            .buttonStyle(.link)
            .controlSize(.small)
            .accessibilityIdentifier("pixiv-retry-pages")
          }
        }
      }
    }
  }

  /// Why the work's page list could not be read, or nil while it loads or once it has.
  private var pagesFailure: String? {
    if case .failed(let message) = selection.pages { return message }
    return nil
  }

  // MARK: Actions

  @ViewBuilder
  private var actions: some View {
    switch selection.download {
    case .saved:
      applyButton
    case .pending(let job):
      HStack(spacing: 8) {
        pauseButton(job)
        cancelButton(job)
      }
    case .paused(let job):
      HStack(spacing: 8) {
        resumeButton(job)
        cancelButton(job)
      }
    case .available(let label):
      downloadButton(label)
    }
  }

  private var applyButton: some View {
    let offer = PixivApplyOffer(libraryID: selection.libraryID, target: controller.mediaApplyTarget)
    let key = PanelActionCoordinator.key("activate", id: offer.libraryID)
    return Button {
      controller.launch(key) {
        if offer.reapplies {
          try await controller.reapply(offer.libraryID)
        } else {
          try await controller.activate(offer.libraryID)
        }
      }
    } label: {
      if offer.reapplies {
        Label("Reapply wallpaper", systemImage: "play.fill")
      } else {
        Label("Apply wallpaper", systemImage: "play.fill")
      }
    }
    .buttonStyle(.panelPrimary(size: .regular, expands: true))
    .disabled(!offer.isEnabled || controller.isBusy(key))
    .accessibilityIdentifier("pixiv-apply")
  }

  private func downloadButton(_ label: PixivSelection.Download.Label) -> some View {
    let key = PanelActionCoordinator.key("pixivDownload", id: work.id)
    return Button {
      let work = work
      let page = selection.pageIndex
      controller.launch(key) { try await controller.pixivDownload(workID: work.id, page: page) }
    } label: {
      switch label {
      case .plain: Label("Download", systemImage: "arrow.down.circle")
      case .page(let page): Label("Download page \(page)", systemImage: "arrow.down.circle")
      case .again: Label("Download again", systemImage: "arrow.down.circle")
      }
    }
    .buttonStyle(.panelPrimary(size: .regular, expands: true))
    .disabled(controller.isBusy(key))
    .accessibilityIdentifier("pixiv-download")
  }

  private func pauseButton(_ job: PixivDownloadRow) -> some View {
    Button {
      controller.launch(PanelActionCoordinator.key("pixivPause", id: job.id)) {
        try await controller.pixivPause(id: job.id)
      }
    } label: {
      Label("Pause download", systemImage: "pause.fill").frame(maxWidth: .infinity)
    }
    .buttonStyle(.bordered)
    .controlSize(.large)
    .accessibilityIdentifier("pixiv-pause")
  }

  private func resumeButton(_ job: PixivDownloadRow) -> some View {
    Button {
      controller.launch(PanelActionCoordinator.key("pixivResume", id: job.id)) {
        try await controller.pixivResume(id: job.id)
      }
    } label: {
      Label("Resume download", systemImage: "play.fill")
    }
    .buttonStyle(.panelPrimary(size: .regular, expands: true))
    .accessibilityIdentifier("pixiv-resume")
  }

  private func cancelButton(_ job: PixivDownloadRow) -> some View {
    Button {
      controller.launch(PanelActionCoordinator.key("pixivCancel", id: job.id)) {
        try await controller.pixivCancel(id: job.id)
      }
    } label: {
      Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
    }
    .buttonStyle(.bordered)
    .controlSize(.large)
    .help(L("Cancel"))
    .accessibilityLabel(L("Cancel"))
    .accessibilityIdentifier("pixiv-cancel")
  }

  // MARK: Progress and tags

  @ViewBuilder
  private var progress: some View {
    if case .pending(let job) = selection.download {
      VStack(alignment: .leading, spacing: 6) {
        if let fraction = job.progress {
          ProgressView(value: fraction)
        } else {
          ProgressView()
        }
        Text(verbatim: job.inspectorStatus())
          .font(.caption)
          .foregroundStyle(theme.surface.muted.color)
          .monospacedDigit()
      }
      .progressViewStyle(.linear)
      .accessibilityElement(children: .combine)
      .accessibilityLabel(Text("\(job.work.displayTitle) download progress"))
      .accessibilityValue(Text(verbatim: job.inspectorStatus()))
    }
  }

  private var tags: some View {
    TagFlow(spacing: 6) {
      ForEach(Array(work.tags.enumerated()), id: \.offset) { _, tag in
        TagChip(text: tag).frame(maxWidth: 220)
      }
    }
  }

  // MARK: Links

  private var links: some View {
    VStack(alignment: .leading, spacing: 8) {
      if selection.isSaved {
        Button {
          let id = selection.libraryID
          controller.launch(PanelActionCoordinator.key("showInstalled", id: id)) {
            try await controller.showInstalled(id)
          }
        } label: {
          Label("Show in library", systemImage: "photo.on.rectangle")
        }
        .buttonStyle(.link)
        .labelStyle(PixivLinkLabelStyle())
        .accessibilityIdentifier("pixiv-show-in-library")
      }
      if let url = ExternalLink.pixivArtwork(id: work.id) {
        Button {
          ExternalLink.open(url)
        } label: {
          Label("View on pixiv", systemImage: "arrow.up.right.square")
        }
        .buttonStyle(.link)
        .labelStyle(PixivLinkLabelStyle())
        .accessibilityIdentifier("pixiv-view-on-pixiv")
      }
    }
  }
}

/// A glyph and a title for a link-style button, with the glyphs in a column of one width so the
/// titles of stacked links line up.
private struct PixivLinkLabelStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 6) {
      configuration.icon.frame(width: 16)
      configuration.title
    }
  }
}

/// A short block of text with a mark in front of it: a failed save in red, a page list that could
/// not be read in amber. The text is selectable so it can be copied into a bug report.
private struct PixivNotice<Trailing: View>: View {
  enum Style { case failure, warning }

  let message: String
  let style: Style
  @ViewBuilder var trailing: Trailing

  @Environment(\.panelTheme) private var theme

  init(message: String, style: Style, @ViewBuilder trailing: () -> Trailing) {
    self.message = message
    self.style = style
    self.trailing = trailing()
  }

  private var tint: Color {
    style == .failure ? theme.surface.danger.color : theme.surface.warning.color
  }

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 12))
        .foregroundStyle(tint)
        .padding(.top, 1)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 6) {
        Text(verbatim: message)
          .font(.system(size: 12))
          .foregroundStyle(theme.surface.text.color)
          .textSelection(.enabled)
        trailing
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(10)
    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .accessibilityElement(children: .contain)
  }
}

extension PixivNotice where Trailing == EmptyView {
  init(message: String, style: Style) {
    self.init(message: message, style: style) { EmptyView() }
  }
}

/// Previous page, "Page 2 of 3" with a check when that page is saved, and next page.
private struct PixivPageStepper: View {
  let selection: PixivSelection

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let index = selection.pageIndex
    let count = selection.pageCount
    HStack(spacing: 0) {
      step(-1, symbol: "chevron.left", title: L("Previous page"), enabled: index > 0)
      Spacer(minLength: 4)
      HStack(spacing: 5) {
        Text("Page \(index + 1) of \(count)")
          .font(.system(size: 12.5, weight: .medium).monospacedDigit())
          .foregroundStyle(theme.surface.text.color)
        if selection.isSaved {
          Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 12))
            .foregroundStyle(theme.surface.approved.color)
            .help(L("In your library"))
        }
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(spoken)
      .accessibilityAddTraits(.updatesFrequently)
      Spacer(minLength: 4)
      step(1, symbol: "chevron.right", title: L("Next page"), enabled: index < count - 1)
    }
    .padding(.horizontal, 4)
    .frame(height: 32)
    .background(
      theme.surface.card.color, in: RoundedRectangle(cornerRadius: 10, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(theme.surface.divider.color, lineWidth: 0.5)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(L("Pages of this work"))
  }

  /// "Page 2 of 3", and that the page is in the library when it is.
  private var spoken: String {
    let page = L("Page \(selection.pageIndex + 1) of \(selection.pageCount)")
    return selection.isSaved ? "\(page), \(L("In your library"))" : page
  }

  private func step(_ delta: Int, symbol: String, title: String, enabled: Bool) -> some View {
    Button {
      let work = selection.work.id
      let page = selection.pageIndex + delta
      controller.launch("pixivSelectPage") {
        try await controller.pixivSelectPage(workID: work, page: page)
      }
    } label: {
      Image(systemName: symbol)
        .font(.system(size: 12, weight: .semibold))
        .frame(width: 26, height: 24)
        .contentShape(Rectangle())
    }
    .buttonStyle(.borderless)
    .disabled(!enabled)
    .help(title)
    .accessibilityLabel(title)
    .accessibilityIdentifier(delta < 0 ? "pixiv-previous-work-page" : "pixiv-next-work-page")
  }
}
