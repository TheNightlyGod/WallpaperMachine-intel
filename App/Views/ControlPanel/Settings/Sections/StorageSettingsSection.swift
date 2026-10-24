import SwiftUI

/// Settings › Storage: where the library is kept, the files you chose for wallpapers, what can be
/// cleared, backups, and the switches, the report and the performance data that help a bug get fixed.
struct StorageSettingsSection: View {
  private static let location = SettingsItem.Group("location", title: "Wallpaper library location")
  private static let userFiles = SettingsItem.Group("user-files", title: "Wallpaper files you chose")
  private static let caches = SettingsItem.Group("caches")
  static let backup = SettingsItem.Group("backup", title: "Backup")
  private static let troubleshooting = SettingsItem.Group("troubleshooting", title: "Troubleshooting")

  static let libraryLocation = SettingsItem(
    id: "storage.library-location", section: .storage, group: location,
    title: "Wallpaper library and downloads",
    note:
      "Installed wallpapers and downloads are kept in this folder, which can be on an external drive. Settings, Steam sign-ins, caches and the files you chose for wallpapers stay on this Mac.",
    keywords: [
      "Move…", "Move to This Mac…", "Show in Finder", "External drive", "Cancel move",
      "Copying the wallpaper library…", "Ready to move",
    ])

  static let userFilesFolder = SettingsItem(
    id: "storage.user-files", section: .storage, group: userFiles,
    title: "Wallpaper files you chose", keywords: ["Show in Finder"])
  static let userFilesClear = SettingsItem(
    id: "storage.user-files-clear", section: .storage, group: userFiles,
    title: "Clear unused caches…",
    note:
      "Files you pick in a wallpaper’s settings are copied here. “Clear unused caches” only removes caches that can be rebuilt, never files you added.",
    keywords: ["Clear…", "Last clear released \("1 MB")."])

  static let shaderCache = SettingsItem(
    id: "storage.shader-cache", section: .storage, group: caches, title: "Shader cache",
    keywords: ["Clear…"])
  static let logs = SettingsItem(
    id: "storage.logs", section: .storage, group: caches, title: "Logs",
    keywords: ["Show in Finder", "Clear…"])
  static let downloadHistory = SettingsItem(
    id: "storage.download-history", section: .storage, group: caches, title: "Completed downloads",
    keywords: ["Clear history"])
  static let context = SettingsItem(
    id: "storage.context", section: .storage, group: caches, title: "What gets removed")

  static let backupExport = SettingsItem(
    id: "storage.backup-export", section: .storage, group: backup, title: "Back up settings",
    note:
      "Saves a .wmbackup package with the renderer settings, every wallpaper’s options, playlists, collections, presets, favorites and the files you chose for wallpapers. Steam sign-ins, passwords, logs and caches are never included.",
    keywords: ["Export…"])
  static let backupLibrary = SettingsItem(
    id: "storage.backup-library", section: .storage, group: backup,
    title: "Include the wallpaper library",
    note:
      "Copies every installed wallpaper as well, which can take a lot of space. Without it, a restore lists the wallpapers to download or import again."
  )
  static let backupRestore = SettingsItem(
    id: "storage.backup-restore", section: .storage, group: backup, title: "Restore",
    note: "Pick a .wmbackup package to see what it holds before anything is restored.",
    keywords: [
      "Choose backup…", "Cancel restore", "Backup to restore", "Already on this Mac",
      "Before you restore", "Restore at next launch", "Choose another…",
      "Keep what is on this Mac", "Replace with the backup", "In progress", "Working…",
      "Backup progress",
      "A restore is ready and will be applied the next time you open WallpaperMachine. Quit and reopen the app when you are ready; it does not restart on its own.",
      "These items exist here and in the backup. Keep what is on this Mac, or replace it with the backup’s version.",
      "Nothing changes until you quit and reopen WallpaperMachine. The restore is applied before anything else loads, keeps the current files until it has finished, and puts them back if it fails.",
    ])

  static let verbose = SettingsItem(
    id: "storage.verbose-logging", section: .storage, group: troubleshooting,
    title: "Detailed logging",
    note:
      "Records extra detail from now on, including after a restart. Turn it off when you are done."
  )
  static let webInspection = SettingsItem(
    id: "storage.web-inspection", section: .storage, group: troubleshooting,
    title: "Allow inspecting web wallpapers",
    note:
      "Lets Safari’s Develop menu attach to the web wallpapers running on this Mac so you can debug a page. Turn it off when you are done."
  )
  static let diagnostics = SettingsItem(
    id: "storage.diagnostics", section: .storage, group: troubleshooting,
    title: "Diagnostics report",
    note:
      "Saves recent logs, the lock screen log, macOS crash, resource, spin and hang reports, which wallpapers were loading when WallpaperMachine quit unexpectedly, and a system summary as one .zip file to attach to a bug report. Home folder paths, your Mac user name and Steam account names are replaced.",
    keywords: ["Export…"])
  static let performanceData = SettingsItem(
    id: "storage.telemetry", section: .storage, group: troubleshooting,
    title: "Send performance data",
    note:
      "Sends once a day: how long wallpapers take to apply, their frame rate and energy use, how the app quit, your Mac’s model, and the Workshop ids of the wallpapers measured. No names, files or account details. Turning it off asks for the sent data to be deleted."
  )
  static let performanceDataFile = SettingsItem(
    id: "storage.telemetry-data", section: .storage, group: troubleshooting,
    title: "Data to be sent", keywords: ["Show in Finder", "What is sent", "Nothing sent yet."])

  static let items = [
    libraryLocation, userFilesFolder, userFilesClear, shaderCache, logs, downloadHistory, context, backupExport,
    backupLibrary, backupRestore, verbose, webInspection, diagnostics, performanceData,
    performanceDataFile,
  ]

  var body: some View {
    SettingsPage(.storage) {
      SettingsGroup(Self.location, in: .storage) { StorageLocationRows() }
      SettingsGroup(Self.userFiles, in: .storage) { StorageUserFilesRows() }
      SettingsGroup(Self.caches, in: .storage) {
        StorageCacheRows()
        SettingsDisclosure(Self.context) { StorageContextContent() }
      }
      SettingsGroup(Self.backup, in: .storage) { StorageBackupRows() }
      SettingsGroup(Self.troubleshooting, in: .storage) { StorageTroubleshootingRows() }
    }
    // Row buttons and switches share one size across Settings.
    .controlSize(.small)
  }
}

// MARK: - Library location

/// Where the library and the downloads are, Move… and Move to This Mac…, the copy of a move being
/// prepared, and the move that waits for the next launch.
private struct StorageLocationRows: View {
  @Environment(PanelController.self) private var controller
  @Environment(\.locale) private var locale
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let location = controller.libraryLocation
    // Also while either move has its folder picker or confirmation open.
    let canMove =
      !location.isCopying && location.pending == nil
      && !controller.isBusy(PanelActionCoordinator.key("moveLibrary"))
      && !controller.isBusy(PanelActionCoordinator.key("moveLibraryToThisMac"))
    DisplaysRow(
      item: StorageSettingsSection.libraryLocation, details: [location.current.path], labelsControl: false
    ) {
      HStack(spacing: 8) {
        Button("Show in Finder") {
          controller.launch(PanelActionCoordinator.key("showLibrary")) { try await controller.showLibrary() }
        }
        if !location.isOnThisMac {
          Button("Move to This Mac…") {
            controller.launch(PanelActionCoordinator.key("moveLibraryToThisMac")) {
              try await controller.moveLibraryToThisMac()
            }
          }
          .disabled(!canMove)
        }
        Button("Move…") {
          controller.launch(PanelActionCoordinator.key("moveLibrary")) { try await controller.moveLibrary() }
        }
        .disabled(!canMove)
      }
    }

    if let copied = location.copiedBytes {
      let total = location.totalBytes
      DisplaysRow(
        item: StorageSettingsSection.libraryLocation, title: L("Copying the wallpaper library…"), note: "",
        details: [
          L("\(ByteSize.text(Double(copied), locale: locale)) of \(ByteSize.text(Double(total), locale: locale))")
        ], labelsControl: false
      ) {
        Button("Cancel") {
          controller.launch(PanelActionCoordinator.key("cancelLibraryCopy")) {
            try await controller.cancelLibraryCopy()
          }
        }
      }
      ProgressView(value: Double(min(copied, total)), total: Double(max(total, 1)))
        .progressViewStyle(.linear)
        .accessibilityLabel(Text("Copy progress"))
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    } else if let pending = location.pending {
      DisplaysRow(
        item: StorageSettingsSection.libraryLocation, title: L("Ready to move"),
        note: pending.target.map {
          L(
            "The library moves to “\($0.path)” the next time you open WallpaperMachine. Quit and reopen the app when you are ready; it does not restart on its own."
          )
        }
          ?? L(
            "The library moves back to this Mac the next time you open WallpaperMachine. Quit and reopen the app when you are ready; it does not restart on its own."
          ), labelsControl: false
      ) {
        Button("Cancel move") {
          controller.launch(PanelActionCoordinator.key("cancelLibraryMove")) {
            try await controller.cancelLibraryMove()
          }
        }
        .foregroundStyle(theme.surface.danger.color)
      }
    }

    let failure = location.isCopying ? nil : location.error
    if let failure {
      DisplaysMessageRow(text: failure, isError: true)
    }
    Color.clear.frame(height: 0).accessibilityHidden(true).announcesChanges(of: failure)
  }
}

// MARK: - Wallpaper files you chose

private struct StorageUserFilesRows: View {
  @Environment(PanelController.self) private var controller
  @Environment(\.locale) private var locale

  var body: some View {
    let state = controller.storageState
    let busy = controller.isStoreBusy
    // A missing path reads as a placeholder, not in the monospaced type of a path.
    let path = state.userAssetsPath
    DisplaysRow(
      item: StorageSettingsSection.userFilesFolder, title: path.isEmpty ? L("Unavailable") : path, note: "",
      isPath: !path.isEmpty, isPlaceholder: path.isEmpty, labelsControl: false
    ) {
      Button("Show in Finder") {
        controller.launch(PanelActionCoordinator.key("revealUserAssets")) {
          try await controller.revealUserAssets()
        }
      }
      .disabled(busy)
    }
    // "Clear unused caches" is told apart from the files themselves: it only removes what can be
    // rebuilt, and says how much the last clear released.
    let released = state.lastClearNote(locale: locale)
    DisplaysRow(
      item: StorageSettingsSection.userFilesClear, title: L("Clear unused caches"),
      note: released.map {
        "\(L("Files you pick in a wallpaper’s settings are copied here. “Clear unused caches” only removes caches that can be rebuilt, never files you added.")) \($0)"
      }, labelsControl: false
    ) {
      Button("Clear…") {
        controller.launch(PanelActionCoordinator.key("purgeUnreferencedUserAssets")) {
          try await controller.purgeUnreferencedUserAssets()
        }
      }
      .disabled(busy)
    }
  }
}

// MARK: - Shader cache, logs, completed downloads

private struct StorageCacheRows: View {
  @Environment(PanelController.self) private var controller
  @Environment(\.locale) private var locale

  var body: some View {
    let state = controller.storageState
    let busy = controller.isStoreBusy
    DisplaysRow(
      item: StorageSettingsSection.shaderCache,
      details: [ByteSize.format(Double(state.shaderCacheBytes), locale: locale)], labelsControl: false
    ) {
      Button("Clear…") {
        controller.launch(PanelActionCoordinator.key("clearCache")) {
          try await controller.clearShaderCache()
        }
      }
      .disabled(busy || !state.canClearShaderCache)
    }
    DisplaysRow(
      item: StorageSettingsSection.logs,
      details: [ByteSize.format(Double(state.logBytes), locale: locale)], labelsControl: false
    ) {
      HStack(spacing: 8) {
        Button("Show in Finder") {
          controller.launch(PanelActionCoordinator.key("showLogs")) { try await controller.showLogs() }
        }
        .disabled(busy)
        Button("Clear…") {
          controller.launch(PanelActionCoordinator.key("clearLogs")) { try await controller.clearLogs() }
        }
        .disabled(busy || !state.canClearLogs)
      }
    }
    DisplaysRow(item: StorageSettingsSection.downloadHistory, labelsControl: false) {
      Button("Clear history") {
        controller.launch(PanelActionCoordinator.key("clearDownloads")) {
          try await controller.clearDownloads()
        }
      }
      .disabled(busy || !controller.downloadQueue.canClearFinished)
    }
  }
}

private struct StorageContextContent: View {
  @Environment(\.panelTheme) private var theme

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(
        "Clearing the shader cache removes compiled shaders and render pipelines. They are rebuilt as wallpapers load, which can briefly slow playback. Clearing logs doesn’t affect wallpapers or settings. Clearing download history keeps the downloaded files."
      )
      Text(
        "Files you chose in a wallpaper’s settings are copied to the folder above, so clearing caches or updating the wallpaper won’t remove them. To remove one, clear that setting on the wallpaper."
      )
    }
    .font(.system(size: 12))
    .foregroundStyle(theme.surface.muted.color)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
  }
}

// MARK: - Backup

private struct StorageBackupRows: View {
  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let presentation = controller.backupPresentation
    let model = controller.displaysSettings.backup
    let busy = controller.isStoreBusy
    let canStart = model.canStart

    DisplaysRow(item: StorageSettingsSection.backupExport, labelsControl: false) {
      Button("Export…") {
        controller.launch(PanelActionCoordinator.key("backupExport")) { try await model.export() }
      }
      .buttonStyle(.panelPrimary(size: .small))
      .disabled(!canStart)
    }
    SettingsRow(StorageSettingsSection.backupLibrary) {
      Toggle(noLabel, isOn: Binding(get: { model.includeLibrary }, set: { model.includeLibrary = $0 }))
        .toggleStyle(.switch)
        .labelsHidden()
        .disabled(!canStart)
    }

    if presentation.isBusy {
      DisplaysRow(
        item: StorageSettingsSection.backupRestore, title: L("In progress"), note: "",
        details: [presentation.workingText], labelsControl: false
      ) {
        Button("Cancel") {
          controller.launch(PanelActionCoordinator.key("backupCancel")) {
            try await controller.cancelBackup()
          }
        }
      }
      ProgressView()
        .progressViewStyle(.linear)
        .accessibilityLabel(Text("Backup progress"))
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    switch presentation.restoreStage {
    case .pendingRestore:
      DisplaysRow(
        item: StorageSettingsSection.backupRestore,
        note:
          L(
            "A restore is ready and will be applied the next time you open WallpaperMachine. Quit and reopen the app when you are ready; it does not restart on its own."
          ), labelsControl: false
      ) {
        Button("Cancel restore") {
          controller.launch(PanelActionCoordinator.key("backupCancelRestore")) {
            try await controller.cancelPendingRestore()
          }
        }
        .foregroundStyle(theme.surface.danger.color)
        .disabled(busy || presentation.isBusy)
      }
    case .preview(let preview):
      StorageBackupPreviewRows(preview: preview, canStart: canStart)
    case .idle:
      DisplaysRow(item: StorageSettingsSection.backupRestore, labelsControl: false) {
        Button("Choose backup…") {
          controller.launch(PanelActionCoordinator.key("backupPreview")) { try await model.choose() }
        }
        .disabled(!canStart)
      }
    }

    // The result of the last operation, once it is not working any more. VoiceOver reads it out as
    // it arrives.
    let result = presentation.isBusy ? nil : presentation.error.flatMap { $0.isEmpty ? nil : $0 }
    let status = presentation.isBusy ? nil : presentation.status.flatMap { $0.isEmpty ? nil : $0 }
    if let result {
      DisplaysMessageRow(text: result, isError: true)
    } else if let status {
      DisplaysMessageRow(text: status)
    }
    Color.clear.frame(height: 0).accessibilityHidden(true).announcesChanges(of: result ?? status)
  }
}

/// A package that was read: what it holds, where it disagrees with this Mac, what to check, and the
/// choice to restore it at the next launch.
private struct StorageBackupPreviewRows: View {
  let preview: BackupPresentation.Preview
  let canStart: Bool

  @Environment(PanelController.self) private var controller
  @Environment(\.locale) private var locale
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let model = controller.displaysSettings.backup
    DisplaysRow(
      item: StorageSettingsSection.backupRestore, title: L("Backup to restore"), note: "",
      details: [preview.factsLine(locale: locale), preview.countsLine]
    ) { EmptyView() }

    if !preview.conflicts.isEmpty {
      DisplaysRow(
        item: StorageSettingsSection.backupRestore, title: L("Already on this Mac"),
        note: L(
          "These items exist here and in the backup. Keep what is on this Mac, or replace it with the backup’s version."
        ), details: preview.conflicts, labelsControl: false, stacked: true
      ) {
        Picker(
          L("Where the backup and this Mac disagree"),
          selection: Binding(get: { model.policy }, set: { model.policy = $0 })
        ) {
          Text("Keep what is on this Mac").tag(WallpaperBackupConflictPolicy.keepExisting)
          Text("Replace with the backup").tag(WallpaperBackupConflictPolicy.replace)
        }
        .pickerStyle(.radioGroup)
        .disabled(!canStart)
      }
    }

    if !preview.warnings.isEmpty {
      DisplaysRow(
        item: StorageSettingsSection.backupRestore, title: L("Before you restore"), note: "",
        warnings: preview.warnings
      ) { EmptyView() }
    }

    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Spacer(minLength: 0)
        Button("Choose another…") {
          controller.launch(PanelActionCoordinator.key("backupPreview")) { try await model.choose() }
        }
        .disabled(!canStart)
        Button("Restore at next launch") {
          controller.launch(PanelActionCoordinator.key("backupRestore")) { try await model.restore() }
        }
        .buttonStyle(.panelPrimary(size: .small))
        .disabled(!canStart)
      }
      Text(
        "Nothing changes until you quit and reopen WallpaperMachine. The restore is applied before anything else loads, keeps the current files until it has finished, and puts them back if it fails."
      )
      .font(.system(size: 11.5))
      .foregroundStyle(theme.surface.muted.color)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }
}

// MARK: - Troubleshooting

private struct StorageTroubleshootingRows: View {
  @Environment(PanelController.self) private var controller

  var body: some View {
    let model = controller.displaysSettings
    let state = controller.storageState
    let busy = controller.isStoreBusy

    SettingsRow(StorageSettingsSection.verbose) {
      Toggle(
        noLabel,
        isOn: model.binding(
          PanelActionCoordinator.key("setting", detail: "verboseLogging"), current: state.verboseLogging
        ) { try await controller.setVerboseLogging($0) }
      )
      .toggleStyle(.switch)
      .labelsHidden()
      .disabled(busy)
    }
    SettingsRow(StorageSettingsSection.webInspection) {
      Toggle(
        noLabel,
        isOn: model.binding(
          PanelActionCoordinator.key("setting", detail: "inspectWebWallpapers"),
          current: state.inspectsWebWallpapers
        ) { try await controller.setInspectsWebWallpapers($0) }
      )
      .toggleStyle(.switch)
      .labelsHidden()
      .disabled(busy)
    }
    DisplaysRow(item: StorageSettingsSection.diagnostics, labelsControl: false) {
      Button("Export…") {
        controller.launch(PanelActionCoordinator.key("exportDiagnostics")) {
          try await controller.exportDiagnostics()
        }
      }
      .disabled(busy)
    }
    StoragePerformanceDataRows()
  }
}

/// **Send performance data** and, beside it, the report the next upload would send and what a
/// report holds (docs/features/telemetry.md). Without a telemetry service the switch is disabled.
private struct StoragePerformanceDataRows: View {
  @Environment(PanelController.self) private var controller
  @Environment(\.locale) private var locale

  var body: some View {
    let model = controller.displaysSettings
    let state = controller.performanceData
    let isOn = state?.isEnabled ?? false
    SettingsRow(StorageSettingsSection.performanceData) {
      Toggle(
        noLabel,
        isOn: model.binding(PanelActionCoordinator.key("setting", detail: "telemetry"), current: isOn) {
          try await controller.setSendsPerformanceData($0)
        }
      )
      .toggleStyle(.switch)
      .labelsHidden()
      .disabled(state == nil)
    }
    DisplaysRow(
      item: StorageSettingsSection.performanceDataFile, note: isOn ? lastSent(state?.lastSentAt) : nil,
      labelsControl: false
    ) {
      HStack(spacing: 8) {
        Button("Show in Finder") {
          controller.launch(PanelActionCoordinator.key("telemetryShowData")) {
            try await controller.showPerformanceData()
          }
        }
        .disabled(!isOn || controller.isBusy(PanelActionCoordinator.key("telemetryShowData")))
        Button("What is sent") {
          controller.launch(PanelActionCoordinator.key("telemetryDetails")) {
            try controller.openPerformanceDataDetails()
          }
        }
      }
    }
  }

  private func lastSent(_ date: Date?) -> String {
    guard let date else { return L("Nothing sent yet.") }
    let day = date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale))
    return L("Last sent on \(day).")
  }
}
