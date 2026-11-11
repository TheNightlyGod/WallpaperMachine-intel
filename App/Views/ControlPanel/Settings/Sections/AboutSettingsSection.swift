import AppKit
import SwiftUI

/// Settings › About: the product, its version, updates with the notes of the latest release, and who
/// built what on what.
struct AboutSettingsSection: View {
  private static let versions = SettingsItem.Group("versions")
  private static let updates = SettingsItem.Group("updates", title: "Updates")
  static let releaseNotes = SettingsItem.Group("release-notes", title: "Release notes")
  private static let share = SettingsItem.Group("share", title: "Spread the word")
  private static let credits = SettingsItem.Group("credits")

  static let appVersion = SettingsItem(
    id: "about.app-version", section: .about, group: versions, title: "App version")
  static let gitRevision = SettingsItem(
    id: "about.git-revision", section: .about, group: versions, title: "Git revision")

  static let updateStatus = SettingsItem(
    id: "about.update-status", section: .about, group: updates, title: "Updates",
    keywords: [
      "Updates not yet checked", "Up to date", "Checking for updates...",
      "No published update is available yet. You can keep using this version.",
      "In-app updates are available only in installed builds.",
    ])
  static let updateActions = SettingsItem(
    id: "about.update-actions", section: .about, group: updates, title: "Check for Updates",
    keywords: [
      "Check Again", "Retry", "Download Update", "Restart and Install", "Retry installation",
      "Cancel", "Open GitHub Releases", "Show in Finder", "Update download progress",
    ])
  static let updateAutomatic = SettingsItem(
    id: "about.update-automatic", section: .about, group: updates,
    title: "Update mode",
    note:
      "Updates download in the background and install while the display sleeps or the Mac is locked; WallpaperMachine quits and reopens to finish.",
    keywords: ["Check and notify", "Download automatically", "Download and install automatically"]
  )
  static let updateNotes = SettingsItem(
    id: "about.update-notes", section: .about, group: releaseNotes, title: "Release notes",
    keywords: ["What’s new"])
  static let earlierReleases = SettingsItem(
    id: "about.earlier-releases", section: .about, group: releaseNotes, title: "Earlier versions",
    note: "Release notes include up to 20 recent versions. Older changes are available on GitHub.")
  static let shareApp = SettingsItem(
    id: "about.share", section: .about, group: share, title: "Share WallpaperMachine…",
    keywords: ["Star on GitHub"])

  static let creditsItem = SettingsItem(
    id: "about.credits", section: .about, group: credits, title: "GNU General Public License v3",
    note:
      "Not affiliated with Wallpaper Engine or Valve. WallpaperMachine itself is open source under GPL-3.0-only. Workshop browsing is independently implemented. No warranty is provided.",
    keywords: ["MMFoundation", "Join Discord"]
  )

  static let items = [
    appVersion, gitRevision, updateStatus, updateActions, updateAutomatic, updateNotes,
    earlierReleases,
    shareApp,
    creditsItem,
  ]

  /// The release notes rows while there are no notes to show, or no version before the newest.
  @MainActor
  static func unofferedItems(_ controller: PanelController) -> Set<String> {
    let count = controller.updater.notesReleases.count
    if count == 0 { return [updateNotes.id, earlierReleases.id] }
    return count == 1 ? [earlierReleases.id] : []
  }

  @Environment(PanelController.self) private var controller

  var body: some View {
    SettingsPage(.about) {
      // The product header is the page's face, not a setting: a search shows only what it finds.
      if !controller.settings.search.isActive { AboutProductHeader() }
      SettingsGroup(Self.versions, in: .about) { AboutVersionRows() }
      SettingsGroup(Self.updates, in: .about) { AboutUpdatesRows() }
      AboutReleaseNotesGroup()
      SettingsGroup(Self.share, in: .about) { AboutShareRow() }
      SettingsGroup(Self.credits, in: .about) { AboutCreditsRow() }
    }
    // Row buttons share one size across Settings.
    .controlSize(.small)
  }
}

// MARK: - Product header

/// The app's icon as the Dock shows it, its name and version. The icon follows the Dock icon choice
/// of Settings › Appearance, or the season's while one is on.
private struct AboutProductHeader: View {
  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let version = controller.aboutInfo.version
    HStack(spacing: 16) {
      Image(nsImage: AboutIcons.image(named: controller.dockIconName))
        .resizable()
        .interpolation(.high)
        .frame(width: 72, height: 72)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 3) {
        Text(verbatim: "WallpaperMachine")
          .font(.system(size: 22, weight: .bold))
          .accessibilityAddTraits(.isHeader)
        Text("Independent macOS client")
          .font(.system(size: 13))
          .foregroundStyle(theme.surface.muted.color)
        if !version.isEmpty {
          Text("Version \(version)")
            .font(.system(size: 12))
            .foregroundStyle(theme.surface.muted.color)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 4)
    .accessibilityElement(children: .combine)
  }
}

/// The Dock icons, decoded once: they are 1024-pixel artwork that the header only shows small.
@MainActor
private enum AboutIcons {
  private static var cache: [String: NSImage] = [:]

  static func image(named name: String) -> NSImage {
    if let cached = cache[name] { return cached }
    let image =
      (try? AppThemePreferences.dockImage(named: name)) ?? NSApp.applicationIconImage ?? NSImage()
    cache[name] = image
    return image
  }
}

// MARK: - Versions

private struct AboutVersionRows: View {
  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let info = controller.aboutInfo
    // The value is what VoiceOver reads after the row's title, so the row does not rename it.
    DisplaysRow(item: AboutSettingsSection.appVersion, labelsControl: false) {
      value(info.version, monospaced: false)
    }
    DisplaysRow(item: AboutSettingsSection.gitRevision, labelsControl: false) {
      value(info.gitRevision, monospaced: true)
    }
  }

  /// A version, or "Unavailable" in the regular type: a placeholder does not take the monospaced
  /// type of a revision, so it does not read as one.
  private func value(_ text: String, monospaced: Bool) -> some View {
    Text(verbatim: text.isEmpty ? L("Unavailable") : text)
      .font(.system(size: 12, design: monospaced && !text.isEmpty ? .monospaced : .default))
      .foregroundStyle(theme.surface.muted.color)
  }
}

// MARK: - Updates

/// Which of the update buttons can be pressed. Nothing here waits on a wallpaper command except the
/// primary button, because an update never touches the renderer until it is installed.
struct AboutUpdateControls: Equatable {
  /// The card is working: checking, downloading or preparing, or one of its buttons is on the way.
  var isBusy: Bool
  var primaryIsDisabled: Bool
  var releasesIsDisabled: Bool
  var revealIsDisabled: Bool

  /// - Parameters:
  ///   - isPending: whether the action of that name is running.
  static func make(
    presentation: UpdatePresentation, isStoreBusy: Bool, isPending: (UpdatePresentation.Action) -> Bool,
    openingReleases: Bool, revealing: Bool
  ) -> AboutUpdateControls {
    let anyPending =
      [.checkForUpdates, .downloadUpdate, .installUpdate, .retryUpdate].contains(where: isPending)
      || openingReleases || revealing
    let busy = presentation.isBusy || anyPending
    // Cancel stays possible while the update is being prepared; only its own press disables it.
    let primaryDisabled =
      presentation.action == .cancelUpdate ? isPending(.cancelUpdate) : busy || isStoreBusy
    return AboutUpdateControls(
      isBusy: busy, primaryIsDisabled: primaryDisabled, releasesIsDisabled: busy,
      revealIsDisabled: busy)
  }
}

/// The first row of Updates: a mark for the kind of news, what the updater says, quiet lines
/// under it (when the update installs, when it last reached GitHub) and the one thing to do next at
/// the trailing edge. The other choices for an update on offer sit in a row of their own beneath,
/// so they never squeeze the status into a column.
private struct AboutUpdateStatusRow<Primary: View, Secondary: View>: View {
  let presentation: UpdatePresentation
  let details: [String]
  let hasSecondary: Bool
  @ViewBuilder var primary: Primary
  @ViewBuilder var secondary: Secondary

  @Environment(\.panelTheme) private var theme

  /// The mark's column: the text and the row beneath start after it.
  private static var markWidth: CGFloat { 20 }
  private static var markSpacing: CGFloat { 10 }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      DisplaysRowLayout(spacing: 12) {
        HStack(alignment: .center, spacing: Self.markSpacing) {
          mark.frame(width: Self.markWidth, height: Self.markWidth)
          VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: presentation.statusText)
              .font(.system(size: 13, weight: .medium))
              .foregroundStyle(theme.surface.text.color)
            ForEach(details, id: \.self) { line in
              Text(verbatim: line)
                .font(.system(size: 11.5))
                .foregroundStyle(theme.surface.muted.color)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        // One subview whatever the button is, and none that vanishes: the layout reads two.
        ZStack { primary }
      }
      if hasSecondary {
        secondary.padding(.leading, Self.markWidth + Self.markSpacing)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .frame(minHeight: 44)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(AboutSettingsSection.updateStatus.id)
  }

  @ViewBuilder
  private var mark: some View {
    switch presentation.mark {
    case .working:
      ProgressRing(value: nil).frame(width: 16, height: 16)
    case .current:
      symbol("checkmark.circle.fill", theme.surface.approved.color)
    case .update:
      symbol("arrow.down.circle.fill", theme.accent.accent.color)
    case .failed:
      symbol("exclamationmark.triangle.fill", theme.surface.warning.color)
    case .neutral:
      symbol("arrow.triangle.2.circlepath.circle.fill", theme.surface.faint.color)
    }
  }

  private func symbol(_ name: String, _ color: Color) -> some View {
    Image(systemName: name)
      .font(.system(size: 18))
      .foregroundStyle(color)
      .accessibilityHidden(true)
  }
}

private struct AboutUpdatesRows: View {
  @Environment(PanelController.self) private var controller
  @Environment(\.locale) private var locale
  @Environment(\.panelTheme) private var theme

  private static func key(_ action: UpdatePresentation.Action) -> String {
    PanelActionCoordinator.key(action.rawValue)
  }

  var body: some View {
    let presentation = controller.updatePresentation(locale: locale)
    let controls = AboutUpdateControls.make(
      presentation: presentation, isStoreBusy: controller.isStoreBusy,
      isPending: { controller.isBusy(Self.key($0)) },
      openingReleases: controller.isBusy(PanelActionCoordinator.key("openReleases")),
      revealing: controller.isBusy(PanelActionCoordinator.key("revealDownloadedUpdate")))
    let search = controller.settings.search

    if search.shows(AboutSettingsSection.updateStatus) || search.shows(AboutSettingsSection.updateActions) {
      let notice = AppUpdateNotice(store: controller.updater)
      let showsActions = search.shows(AboutSettingsSection.updateActions)
      AboutUpdateStatusRow(
        presentation: presentation, details: details(notice),
        hasSecondary: showsActions && (notice != nil || presentation.showsReleases || presentation.showsReveal)
      ) {
        if showsActions { primaryAction(presentation, controls) }
      } secondary: {
        secondaryActions(presentation, controls, notice)
      }
      .accessibilityIdentifier(AboutSettingsSection.updateActions.id)
      // The status line is a status the page reads out when it changes: checking, found, failed. A
      // download's percent changes its words, not its state, and is not read out at each step.
      .announcesChanges(of: presentation.status, saying: presentation.statusText)
    }
    if let download = presentation.download {
      VStack(alignment: .leading, spacing: 4) {
        ProgressView(value: min(max(download.percent / 100, 0), 1))
          .progressViewStyle(.linear)
          .accessibilityLabel(Text(verbatim: UpdatePresentation.progressLabel))
        if download.total > 0 {
          Text(
            verbatim: L(
              "\(TransferFormat.bytes(Double(download.transferred), locale: locale)) of \(TransferFormat.bytes(Double(download.total), locale: locale))"
            )
          )
          .font(.system(size: 11.5))
          .foregroundStyle(theme.surface.muted.color)
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
    }
    DisplaysRow(item: AboutSettingsSection.updateAutomatic, title: L("Update mode"),
                note: controller.updater.mode.explanation) {
      UpdateModePicker()
    }
  }

  /// The quiet lines under the status: what the notice says where the status line does not already
  /// (an update that waits for the Mac to lock, one put off, one just installed), then the last
  /// successful check.
  private func details(_ notice: AppUpdateNotice?) -> [String] {
    var lines: [String] = []
    if let notice {
      switch notice.kind {
      case .ready where notice.automatic: lines.append(notice.title)
      case .deferred, .installed: lines.append(notice.title)
      default: break
      }
    }
    if let checked = controller.updater.lastCheckedAt {
      let time = checked.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))
      lines.append(L("Last successful check: \(time)"))
    }
    return lines
  }

  /// The one thing to do next: check, download, install, cancel or retry.
  @ViewBuilder
  private func primaryAction(_ presentation: UpdatePresentation, _ controls: AboutUpdateControls)
    -> some View
  {
    if let action = presentation.action {
      let label = presentation.actionLabel.isEmpty ? L("Check for Updates") : presentation.actionLabel
      Group {
        if presentation.isActionProminent {
          Button(label) { run(action) }.buttonStyle(.panelPrimary(size: .small))
        } else {
          Button(label) { run(action) }
        }
      }
      .fixedSize()
      .disabled(controls.primaryIsDisabled
        || (controller.updater.installIsScheduled && presentation.action != .cancelUpdate))
    }
  }

  /// Under the status: Skip This Version and Remind Me Later for an update on offer (Dismiss for
  /// one just installed), then Open GitHub Releases or Show in Finder. They wrap rather than ask a
  /// narrow window for their row's width.
  private func secondaryActions(
    _ presentation: UpdatePresentation, _ controls: AboutUpdateControls, _ notice: AppUpdateNotice?
  ) -> some View {
    TagFlow(spacing: 8, centersRows: true) {
      if let notice {
        if notice.kind == .installed {
          Button("Dismiss") {
            controller.launch(PanelActionCoordinator.key("dismissRecentUpdate")) {
              try await controller.dismissRecentUpdate()
            }
          }
        } else {
          Button("Remind Me Later") {
            controller.launch(PanelActionCoordinator.key("postponeUpdate")) {
              try await controller.postponeUpdate()
            }
          }
          Button("Skip This Version") {
            controller.launch(PanelActionCoordinator.key("skipUpdate")) { try await controller.skipUpdate() }
          }
          .disabled(presentation.isBusy)
        }
      }
      if presentation.showsReleases {
        Button(UpdatePresentation.releasesLabel) {
          controller.launch(PanelActionCoordinator.key("openReleases")) {
            try await controller.openReleases()
          }
        }
        .disabled(controls.releasesIsDisabled)
      }
      if presentation.showsReveal {
        Button(UpdatePresentation.revealLabel) {
          controller.launch(PanelActionCoordinator.key("revealDownloadedUpdate")) {
            try await controller.revealDownloadedUpdate()
          }
        }
        .disabled(controls.revealIsDisabled)
      }
    }
  }

  private func run(_ action: UpdatePresentation.Action) {
    controller.launch(Self.key(action)) {
      switch action {
      case .checkForUpdates: try await controller.checkForUpdates()
      case .downloadUpdate: try await controller.downloadUpdate()
      case .installUpdate: _ = try await controller.installUpdate()
      case .cancelUpdate: try await controller.cancelUpdate()
      case .retryUpdate: try await controller.retryUpdate()
      }
    }
  }
}

// MARK: - Credits

/// **Share WallpaperMachine…** opens the system share menu with the website; **Star on GitHub**
/// opens the repository and counts as the star the star prompt would ask for.
private struct AboutShareRow: View {
  @Environment(PanelController.self) private var controller

  var body: some View {
    let item = AboutSettingsSection.shareApp
    if controller.settings.search.shows(item) {
      let share = controller.appShare
      HStack(spacing: 8) {
        ShareLink(
          item: share.url, subject: Text(verbatim: share.subject),
          message: Text(verbatim: share.message)
        ) {
          Text("Share WallpaperMachine…")
        }
        Button("Star on GitHub") {
          controller.launch(PanelActionCoordinator.key("starRepository")) {
            try await controller.starRepository()
          }
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier(item.id)
    }
  }
}

private struct AboutCreditsRow: View {
  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let settings = controller.settings
    let item = AboutSettingsSection.creditsItem
    if settings.search.shows(item) {
      VStack(alignment: .leading, spacing: 8) {
        if let note = item.note {
          Text(verbatim: settings.text(note))
            .font(.system(size: 12))
            .foregroundStyle(theme.surface.muted.color)
        }
        HStack(spacing: 8) {
          Button("GNU General Public License v3") { ExternalLink.open(ExternalLink.gnuGPL3) }
          // MMFoundation makes the app; its website is where its other projects and its sponsors are.
          Button { ExternalLink.open(ExternalLink.mmfoundation) } label: {
            Text(verbatim: "MMFoundation")
          }
          .help(ExternalLink.mmfoundation.absoluteString)
          // Its Discord server, which also answers the one-time Discord invitation.
          Button("Join Discord") {
            controller.launch(PanelActionCoordinator.key("joinDiscord")) {
              try await controller.joinDiscord()
            }
          }
          .help(ExternalLink.discord.absoluteString)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier(item.id)
    }
  }
}
