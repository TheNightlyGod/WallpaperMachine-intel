import AppKit
import SwiftUI

/// Settings › About: the product, its version, updates with the notes of the latest release, and who
/// built what on what.
struct AboutSettingsSection: View {
  private static let versions = SettingsItem.Group("versions")
  private static let updates = SettingsItem.Group("updates", title: "Updates")
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
  static let updateNotes = SettingsItem(
    id: "about.update-notes", section: .about, group: updates, title: "What’s new")
  static let updateFootnote = SettingsItem(
    id: "about.update-footnote", section: .about, group: updates, title: "Updates",
    note:
      "Updates are checked against the latest published GitHub Release. Download and restart-install happen only after you confirm."
  )

  static let shareApp = SettingsItem(
    id: "about.share", section: .about, group: share, title: "Share WallpaperMachine…",
    keywords: ["Star on GitHub"])

  static let creditsItem = SettingsItem(
    id: "about.credits", section: .about, group: credits, title: "GNU General Public License v3",
    note:
      "Not affiliated with Wallpaper Engine or Valve. WallpaperMachine itself is open source under GPL-3.0-only. Workshop browsing is independently implemented. No warranty is provided."
  )

  static let items = [
    appVersion, gitRevision, updateStatus, updateActions, updateNotes, updateFootnote, shareApp,
    creditsItem,
  ]

  @Environment(PanelController.self) private var controller

  var body: some View {
    SettingsPage(.about) {
      // The product header is the page's face, not a setting: a search shows only what it finds.
      if !controller.settings.search.isActive { AboutProductHeader() }
      SettingsGroup(Self.versions, in: .about) { AboutVersionRows() }
      SettingsGroup(Self.updates, in: .about) { AboutUpdatesRows() }
      SettingsGroup(Self.share, in: .about) { AboutShareRow() }
      SettingsGroup(Self.credits, in: .about) { AboutCreditsRow() }
    }
    // Row buttons share one size across Settings.
    .controlSize(.small)
  }
}

// MARK: - Product header

/// The app's icon as the Dock shows it, its name and version. The icon follows the Dock icon choice
/// of Settings › Appearance.
private struct AboutProductHeader: View {
  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    // The icon is the person's choice, which SwiftUI cannot see change; its counter is read first.
    let _ = controller.revisions.theme
    let version = controller.aboutInfo.version
    HStack(spacing: 16) {
      Image(nsImage: AboutIcons.image(controller.theme.preferences.icon))
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

/// The three Dock icons, decoded once: they are 1024-pixel artwork that the header only shows small.
@MainActor
private enum AboutIcons {
  private static var cache: [AppThemePreferences.Icon: NSImage] = [:]

  static func image(_ icon: AppThemePreferences.Icon) -> NSImage {
    if let cached = cache[icon] { return cached }
    let image = (try? icon.image()) ?? NSApp.applicationIconImage ?? NSImage()
    cache[icon] = image
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
      [.checkForUpdates, .downloadUpdate, .installUpdate].contains(where: isPending)
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

    DisplaysRow(
      item: AboutSettingsSection.updateStatus, title: presentation.statusText, note: ""
    ) { EmptyView() }
    // The status line is a status the page reads out when it changes: checking, found, failed. A
    // download's percent changes its words, not its state, and is not read out at each step.
    .announcesChanges(of: presentation.status, saying: presentation.statusText)
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
      .padding(.vertical, 8)
    }
    actions(presentation, controls)
    if presentation.hasNotes { notes(presentation) }
    DisplaysItemNote(item: AboutSettingsSection.updateFootnote)
  }

  @ViewBuilder
  private func actions(_ presentation: UpdatePresentation, _ controls: AboutUpdateControls)
    -> some View
  {
    if controller.settings.search.shows(AboutSettingsSection.updateActions) {
      HStack(spacing: 8) {
        if let action = presentation.action {
          let label =
            presentation.actionLabel.isEmpty ? L("Check for Updates") : presentation.actionLabel
          Group {
            if presentation.isActionProminent {
              Button(label) { run(action) }.buttonStyle(.panelPrimary(size: .small))
            } else {
              Button(label) { run(action) }
            }
          }
          .disabled(controls.primaryIsDisabled)
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
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .accessibilityIdentifier(AboutSettingsSection.updateActions.id)
    }
  }

  /// What's new in the latest published release, whether or not it is newer than this build.
  private func notes(_ presentation: UpdatePresentation) -> some View {
    let sections = presentation.notes.filter { !$0.items.isEmpty }
    return DisplaysDisclosure(
      item: AboutSettingsSection.updateNotes, display: "about",
      title: presentation.notesVersion.map { L("What’s new in \($0)") } ?? L("What’s new")
    ) {
      VStack(alignment: .leading, spacing: 10) {
        ForEach(sections.indices, id: \.self) { index in
          let section = sections[index]
          VStack(alignment: .leading, spacing: 4) {
            if !section.title.isEmpty {
              // Known headings (New, Fixed) are translated; any other reads as given.
              Text(verbatim: PanelLocale.shared.catalogString(section.title))
                .font(.system(size: 12, weight: .semibold))
            }
            ForEach(section.items.indices, id: \.self) { item in
              HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: "•").foregroundStyle(theme.surface.faint.color)
                Text(verbatim: section.items[item])
              }
              .font(.system(size: 12))
              .foregroundStyle(theme.surface.muted.color)
            }
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
    }
  }

  private func run(_ action: UpdatePresentation.Action) {
    controller.launch(Self.key(action)) {
      switch action {
      case .checkForUpdates: try await controller.checkForUpdates()
      case .downloadUpdate: try await controller.downloadUpdate()
      case .installUpdate: _ = try await controller.installUpdate()
      case .cancelUpdate: try await controller.cancelUpdate()
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
        Button("GNU General Public License v3") { ExternalLink.open(ExternalLink.gnuGPL3) }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier(item.id)
    }
  }
}
