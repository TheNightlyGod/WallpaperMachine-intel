import SwiftUI

/// Settings › Library & Steam: where wallpapers live, SteamCMD, the shared scene resources, the
/// Workshop updates check, how many downloads run at once, and the Steam account.
struct LibrarySettingsSection: View {
  private static let folder = SettingsItem.Group("folder")
  private static let steamCMD = SettingsItem.Group("steamcmd", title: "SteamCMD")
  private static let scene = SettingsItem.Group("scene", title: "Shared scene resources")
  private static let updates = SettingsItem.Group("updates", title: "Workshop updates")
  private static let downloads = SettingsItem.Group("downloads", title: "Downloads")
  private static let account = SettingsItem.Group("account")

  static let libraryFolder = SettingsItem(
    id: "library.folder", section: .library, group: folder, title: "Wallpaper library",
    keywords: ["Show in Finder"])

  static let steamStatus = SettingsItem(
    id: "library.steamcmd-status", section: .library, group: steamCMD, title: "Installation",
    keywords: [
      "Not installed", "Checking SteamCMD…", "Downloading SteamCMD…", "Extracting SteamCMD…",
      "Validating SteamCMD…", "Saving installation…", "Ready", "Installation cancelled",
      "Setup needs attention", "SteamCMD installation progress",
    ])
  static let steamActions = SettingsItem(
    id: "library.steamcmd-actions", section: .library, group: steamCMD, title: "Install SteamCMD",
    note: "Installation changes are unavailable while downloads are running.",
    keywords: [
      "Reinstall…", "Continue installation", "Cancel installation", "Locate…",
      "Allow this SteamCMD…",
    ])
  static let steamCandidate = SettingsItem(
    id: "library.steamcmd-candidate", section: .library, group: steamCMD,
    title: "Downloaded installation", keywords: ["Show in Finder", "Discard…"])

  static let sceneStatus = SettingsItem(
    id: "library.scene-status", section: .library, group: scene, title: "Installation",
    keywords: [
      "Waiting for SteamCMD setup.", "Waiting for your Steam sign-in.",
      "Waiting for your go-ahead on the download.", "Installed. Scene wallpapers can play.",
      "Not installed. Scene wallpapers cannot play yet.", "Shared resources download progress",
    ])
  static let sceneActions = SettingsItem(
    id: "library.scene-actions", section: .library, group: scene, title: "Download from Steam…",
    note:
      "Steam downloads the full Windows version to a temporary folder, and only the shared resources are kept. No Windows programs are run. You need several GB of free space and a Steam account that owns Wallpaper Engine.",
    keywords: [
      "Download again…", "Finish sign-in…", "Cancel queued download", "Cancel download",
      "Continue setup…", "Remove request", "Locate an installation…",
    ])

  static let updatesDaily = SettingsItem(
    id: "library.updates-daily", section: .library, group: updates, title: "Check once a day",
    note:
      "Asks Steam which of your installed Workshop wallpapers have changed since you got them. Only their ids are sent, and no sign-in is needed."
  )
  static let updatesCheck = SettingsItem(
    id: "library.updates-check", section: .library, group: updates, title: "Last check",
    keywords: [
      "Check Now", "Checking…", "Not checked yet.",
      "\("12:00"): everything is up to date.",
    ])

  static let downloadsAtOnce = SettingsItem(
    id: "library.downloads-at-once", section: .library, group: downloads,
    title: "Downloads at once",
    note:
      "Each download signs in to Steam on its own. More at once mostly helps batches of small wallpapers; large ones share your connection.",
    keywords: [
      "Steam ended one of the sessions, so downloads run one at a time until you reopen the app."
    ])

  static let steamAccount = SettingsItem(
    id: "library.steam-account", section: .library, group: account, title: "Steam account",
    note: "You sign in when a download starts.", keywords: ["Log out…", "Not signed in"])
  static let context = SettingsItem(
    id: "library.context", section: .library, group: account,
    title: "Setup, compatibility & account privacy",
    keywords: ["Wallpaper Engine on Steam", "macOS app security"])

  static let items = [
    libraryFolder, steamStatus, steamActions, steamCandidate, sceneStatus, sceneActions,
    updatesDaily, updatesCheck, downloadsAtOnce, steamAccount, context,
  ]

  var body: some View {
    SettingsPage(.library) {
      SettingsGroup(Self.folder, in: .library) { LibraryFolderRow() }
      SettingsGroup(Self.steamCMD, in: .library) { LibrarySteamCMDRows() }
      SettingsGroup(Self.scene, in: .library) { LibrarySceneRows() }
      SettingsGroup(Self.updates, in: .library) { LibraryUpdatesRows() }
      SettingsGroup(Self.downloads, in: .library) { LibraryDownloadsRow() }
      SettingsGroup(Self.account, in: .library) {
        LibraryAccountRow()
        SettingsDisclosure(Self.context) { LibraryContextContent() }
      }
    }
    // Row buttons, menus and switches share one size across Settings, the left-aligned action
    // rows (SteamCMD, scene resources) included.
    .controlSize(.small)
  }
}

// MARK: - Library folder

private struct LibraryFolderRow: View {
  @Environment(PanelController.self) private var controller

  var body: some View {
    let path = controller.librarySteamSettings.libraryPath
    DisplaysRow(
      item: LibrarySettingsSection.libraryFolder, note: "", details: [path.isEmpty ? L("Unavailable") : path],
      labelsControl: false
    ) {
      Button("Show in Finder") {
        controller.launch(PanelActionCoordinator.key("showLibrary")) { try await controller.showLibrary() }
      }
      .disabled(controller.isStoreBusy)
    }
  }
}

// MARK: - SteamCMD

private struct LibrarySteamCMDRows: View {
  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let setup = controller.steamSetup
    let hasDownload = controller.steamDownloadRows.contains(where: \.isPending)
    let presentation = LibrarySteamCMDPresentation.make(
      setup: setup, hasPendingDownload: hasDownload, isStoreBusy: controller.isStoreBusy)

    // The status is the row's value, which VoiceOver reads after the title.
    DisplaysRow(item: LibrarySettingsSection.steamStatus, note: "", labelsControl: false) {
      Text(verbatim: setup.status)
        .font(.system(size: 12))
        .foregroundStyle(theme.surface.muted.color)
        .accessibilityAddTraits(.updatesFrequently)
    }
    if setup.isBusy, let progress = setup.progress {
      ProgressView(value: min(max(progress, 0), 1))
        .progressViewStyle(.linear)
        .accessibilityLabel(Text("SteamCMD installation progress"))
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
    if let detail = setup.errorDetail {
      DisplaysMessageRow(text: detail, isError: true)
    }
    actions(presentation)
    if presentation.showsCandidate, let path = setup.candidatePath {
      DisplaysRow(
        item: LibrarySettingsSection.steamCandidate, details: [path], labelsControl: false
      ) {
        HStack(spacing: 8) {
          Button("Show in Finder") {
            controller.launch(PanelActionCoordinator.key("setupRevealCandidate")) {
              try await controller.revealSteamCMDCandidate()
            }
          }
          .disabled(presentation.revealIsDisabled)
          Button("Discard…") {
            controller.launch(PanelActionCoordinator.key("setupDiscardCandidate")) {
              try await controller.discardSteamCMDCandidate()
            }
          }
          .foregroundStyle(theme.surface.danger.color)
          .disabled(presentation.discardIsDisabled)
        }
      }
    }
    if presentation.showsDownloadsNote {
      DisplaysItemNote(item: LibrarySettingsSection.steamActions, forced: true)
    }
    // An empty view that is always there, so the error is read out when it arrives.
    Color.clear.frame(height: 0).accessibilityHidden(true).announcesChanges(of: setup.errorDetail)
  }

  /// Install, Reinstall… or Continue, Locate… and Allow this SteamCMD…; Cancel while setup works.
  private func actions(_ presentation: LibrarySteamCMDPresentation) -> some View {
    HStack(spacing: 8) {
      if presentation.showsCancel {
        Button("Cancel installation") {
          controller.launch(PanelActionCoordinator.key("setupCancel")) {
            try await controller.cancelSteamCMDSetup()
          }
        }
        .disabled(presentation.cancelIsDisabled)
      }
      if let primary = presentation.primary {
        button(title(of: primary), prominent: presentation.primaryIsProminent) {
          controller.launch(PanelActionCoordinator.key("setupInstall")) {
            try await controller.installSteamCMD()
          }
        }
        .disabled(presentation.primaryIsDisabled)
      }
      if presentation.showsLocate {
        Button("Locate…") {
          controller.launch(PanelActionCoordinator.key("setupLocate")) {
            try await controller.locateSteamCMD()
          }
        }
        .disabled(presentation.locateIsDisabled)
      }
      if presentation.showsApprove {
        Button("Allow this SteamCMD…") {
          controller.launch(PanelActionCoordinator.key("setupApprove")) {
            try await controller.approveSteamCMD()
          }
        }
        .disabled(presentation.approveIsDisabled)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  private func title(of primary: LibrarySteamCMDPresentation.Primary) -> LocalizedStringKey {
    switch primary {
    case .install: "Install SteamCMD"
    case .reinstall: "Reinstall…"
    case .continueInstallation: "Continue installation"
    }
  }

  @ViewBuilder
  private func button(_ title: LocalizedStringKey, prominent: Bool, _ action: @escaping () -> Void)
    -> some View
  {
    if prominent {
      Button(title, action: action).buttonStyle(.panelPrimary(size: .small))
    } else {
      Button(title, action: action)
    }
  }
}

// MARK: - Shared scene resources

private struct LibrarySceneRows: View {
  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let presentation = LibrarySceneResourcesPresentation.make(
      scene: controller.steamDownloadRow(for: WorkshopStore.sceneAssetsRequestID),
      request: controller.downloadRequestRow(for: WorkshopStore.sceneAssetsRequestID),
      isInstalled: controller.workshop.sceneAssetsReady,
      assetsWarning: controller.workshop.sceneAssetsFailure,
      setupIsBusy: controller.steamSetup.isBusy, isStoreBusy: controller.isStoreBusy)

    DisplaysRow(item: LibrarySettingsSection.sceneStatus, note: "", labelsControl: false) {
      Text(verbatim: presentation.status)
        .font(.system(size: 12))
        .foregroundStyle(theme.surface.muted.color)
        .multilineTextAlignment(.trailing)
        .accessibilityAddTraits(.updatesFrequently)
    }
    if presentation.isPending {
      Group {
        if let progress = presentation.progress {
          ProgressView(value: progress)
        } else {
          ProgressView()
        }
      }
      .progressViewStyle(.linear)
      .accessibilityLabel(Text("Shared resources download progress"))
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
    }
    if let error = presentation.error { DisplaysMessageRow(text: error, isError: true) }
    ForEach(presentation.warnings, id: \.self) { DisplaysMessageRow(text: $0) }
    actions(presentation)
    DisplaysItemNote(item: LibrarySettingsSection.sceneActions, forced: true)
      .announcesChanges(of: presentation.error)
  }

  private func actions(_ presentation: LibrarySceneResourcesPresentation) -> some View {
    let busy = controller.isStoreBusy
    return HStack(spacing: 8) {
      ForEach(presentation.actions.indices, id: \.self) { index in
        let action = presentation.actions[index]
        let prominent = presentation.isProminent(action)
        Group {
          if prominent {
            Button(title(of: action)) { run(action) }.buttonStyle(.panelPrimary(size: .small))
          } else if action == .removeRequest {
            Button(title(of: action)) { run(action) }.foregroundStyle(theme.surface.danger.color)
          } else {
            Button(title(of: action)) { run(action) }
          }
        }
        .disabled(action == .locate ? presentation.locateIsDisabled : busy)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  private func title(of action: LibrarySceneResourcesPresentation.Action) -> LocalizedStringKey {
    switch action {
    case .finishSignIn: "Finish sign-in…"
    case .cancelQueuedDownload: "Cancel queued download"
    case .cancelDownload: "Cancel download"
    case .continueSetup: "Continue setup…"
    case .removeRequest: "Remove request"
    case .download(let installed): installed ? "Download again…" : "Download from Steam…"
    case .locate: "Locate an installation…"
    }
  }

  private func run(_ action: LibrarySceneResourcesPresentation.Action) {
    let id = WorkshopStore.sceneAssetsRequestID
    switch action {
    case .finishSignIn, .continueSetup:
      controller.downloads.openDialog(for: nil)
    case .cancelQueuedDownload, .cancelDownload:
      controller.launch(PanelActionCoordinator.key("downloadCancel", id: id)) {
        try await controller.cancelDownload(id: id)
      }
    case .removeRequest:
      controller.launch(PanelActionCoordinator.key("removeDownloadRequest", id: id)) {
        try await controller.removeDownloadRequest(id: id)
      }
    case .download:
      controller.launch(PanelActionCoordinator.key("requestDownload", id: id)) {
        try await controller.requestSceneAssets()
        // The dialog opens unless the download is already on its way.
        if controller.downloadDialogTarget(afterRequesting: nil) != nil {
          controller.downloads.openDialog(for: nil)
        }
      }
    case .locate:
      controller.launch(PanelActionCoordinator.key("locateAssets")) {
        try await controller.locateSceneAssets()
      }
    }
  }
}

// MARK: - Workshop updates

private struct LibraryUpdatesRows: View {
  @Environment(PanelController.self) private var controller
  @Environment(\.locale) private var locale

  var body: some View {
    let model = controller.displaysSettings
    let settings = controller.librarySteamSettings
    let updates = controller.workshopUpdates
    let busy = controller.isStoreBusy

    SettingsRow(LibrarySettingsSection.updatesDaily) {
      Toggle(
        noLabel,
        isOn: model.binding(
          PanelActionCoordinator.key("setting", detail: "workshopUpdateChecks"),
          current: settings.workshopUpdateChecks
        ) { try await controller.setWorkshopUpdateChecks($0) }
      )
      .toggleStyle(.switch)
      .labelsHidden()
      .disabled(busy)
    }
    DisplaysRow(
      item: LibrarySettingsSection.updatesCheck, note: LibraryUpdatesNote.text(updates, locale: locale),
      labelsControl: false
    ) {
      Button(updates.isChecking ? "Checking…" : "Check Now") {
        controller.launch(PanelActionCoordinator.key("workshopCheckUpdates")) {
          try await controller.checkWorkshopUpdates()
        }
      }
      .disabled(busy || updates.isChecking)
    }
    .announcesChanges(of: updates.errorMessage)
    if let error = updates.errorMessage, !error.isEmpty {
      DisplaysMessageRow(text: error, isError: true)
    }
  }
}

// MARK: - Downloads at once

private struct LibraryDownloadsRow: View {
  @Environment(PanelController.self) private var controller

  var body: some View {
    let model = controller.displaysSettings
    let settings = controller.librarySteamSettings
    let account = controller.steamAccount
    // The setting is the ceiling; after Steam ends a session downloads run one at a time.
    let serialNow = settings.concurrentDownloads > 1 && account.downloadsRunOneAtATimeAfterConflict
    SettingsRow(
      LibrarySettingsSection.downloadsAtOnce,
      note: serialNow
        ? L("Steam ended one of the sessions, so downloads run one at a time until you reopen the app.")
        : nil
    ) {
      Picker(
        noLabel,
        selection: model.binding(
          PanelActionCoordinator.key("setting", detail: "concurrentDownloads"),
          current: settings.concurrentDownloads
        ) { try await controller.setConcurrentDownloads($0) }
      ) {
        ForEach(LibraryDownloadsMenu.choices(settings), id: \.self) { Text(verbatim: "\($0)").tag($0) }
      }
      .displaysMenu()
      .disabled(controller.isStoreBusy)
    }
  }
}

// MARK: - Steam account

private struct LibraryAccountRow: View {
  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let account = controller.steamAccount.saved
    let hasDownload = controller.steamDownloadRows.contains(where: \.isPending)
    DisplaysRow(
      item: LibrarySettingsSection.steamAccount,
      note: LibraryAccountNote.text(account: account, hasPendingDownload: hasDownload), labelsControl: false
    ) {
      if account != nil {
        Button("Log out…") {
          controller.launch(PanelActionCoordinator.key("logOutSteam")) {
            try await controller.logOutSteam()
          }
        }
        .foregroundStyle(theme.surface.danger.color)
        .disabled(hasDownload || controller.isStoreBusy)
      } else {
        Text("Not signed in")
          .font(.system(size: 12))
          .foregroundStyle(theme.surface.muted.color)
      }
    }
  }
}

/// The disclosure's paragraphs, where the shared assets are, and the two pages that explain more.
/// The paragraphs and the path are in the quiet colour; the links are links, in the link colour with
/// the arrow of a page that opens outside the app.
private struct LibraryContextContent: View {
  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let path = controller.workshop.sceneAssetsURL.path
    VStack(alignment: .leading, spacing: 8) {
      paragraphs(path: path)
        .font(.system(size: 12))
        .foregroundStyle(theme.surface.muted.color)
      // The links wrap where the narrowest page cannot hold them side by side.
      TagFlow(spacing: 16) {
        link("Wallpaper Engine on Steam", ExternalLink.wallpaperEngineStore)
        link("macOS app security", ExternalLink.macOSAppSecurity)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
  }

  private func link(_ title: LocalizedStringKey, _ url: URL) -> some View {
    Button { ExternalLink.open(url) } label: {
      HStack(spacing: 3) {
        Text(title)
        Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
      }
      .font(.system(size: 12))
    }
    .buttonStyle(.link)
  }

  private func paragraphs(path: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(
        "Scene wallpapers need shared resources from a purchased Wallpaper Engine installation. Videos do not. Locate its assets folder or download the shared assets once through Steam. Scene support is experimental; effects and scripts may differ from Windows."
      )
      Text(
        "Steam downloads the Windows version to temporary storage; only shared assets are kept. Windows programs are never run. Allow several GB of temporary space. Imports are copied; original files and your Steam library stay untouched."
      )
      Text(
        "SteamCMD is Valve’s download tool; installing it doesn’t require signing in. Downloading requires a Steam account that owns Wallpaper Engine. Your password and Steam Guard codes go straight to SteamCMD and are not saved by this app. “Keep me signed in” stores Steam’s sign-in on this Mac. Logging out only affects this Mac; other devices stay signed in."
      )
      Text(
        "Approve Steam Guard in the Steam mobile app, or enter the fresh code when requested. Steam may require a new sign-in after expiry or security changes. If Steam reports too many attempts, wait before retrying."
      )
      Text(
        "Allowing SteamCMD applies only to the downloaded copy you confirmed. Gatekeeper and signature checks stay on."
      )
      if !path.isEmpty {
        Text(verbatim: path)
          .font(.system(size: 11.5, design: .monospaced))
          .lineLimit(2)
          .truncationMode(.middle)
      }
    }
  }
}
