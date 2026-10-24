import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class WallpaperBackupStore {
    private(set) var busy = false
    private(set) var status: String?
    private(set) var error: String?
    private(set) var preview: WallpaperBackupPreview?
    private(set) var pendingRestore: Bool
    @ObservationIgnored private let service: WallpaperBackupService
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let domainName: String
    @ObservationIgnored private var selectedPackage: URL?
    @ObservationIgnored private var cancelOperation: (() -> Void)?
    @ObservationIgnored var onChange: (() -> Void)?
    /// Injectable file pickers keep service and store tests isolated from desktop UI.
    @ObservationIgnored private let exportDestination: @MainActor () async -> URL?
    @ObservationIgnored private let restoreSource: @MainActor () async -> URL?

    init(service: WallpaperBackupService = .init(storageRoot: ClientPaths.storageURL), defaults: UserDefaults = ClientPreferences.defaults,
         domainName: String = ClientPreferences.domainName,
         exportDestination: (@MainActor () async -> URL?)? = nil,
         restoreSource: (@MainActor () async -> URL?)? = nil) {
        self.service = service
        self.defaults = defaults
        self.domainName = domainName
        pendingRestore = service.pendingRestore
        error = service.lastStartupError
        self.exportDestination = exportDestination ?? Self.chooseExportDestination
        self.restoreSource = restoreSource ?? Self.chooseRestoreSource
        if error != nil && pendingRestore {
            status = String(localized: "A previous restore failed. Preview and confirm the backup again to retry, or cancel the pending restore.")
        }
    }

    func export(includeLibrary: Bool) async throws {
        try requireIdle()
        busy = true
        onChange?()
        defer { busy = false; cancelOperation = nil; onChange?() }
        guard let destination = await exportDestination() else { return }
        let scoped = destination.startAccessingSecurityScopedResource()
        defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
        status = String(localized: "Copying the local backup…")
        error = nil
        do {
            let preferences = try WallpaperBackupPreferences(defaults: defaults, domainName: domainName)
            let service = service
            try await run { try service.export(to: destination, includeLibrary: includeLibrary, preferences: preferences) }
            status = String(localized: "Backup exported. Login sessions, caches and shared scene assets were not included.")
        } catch is CancellationError {
            status = String(localized: "Backup operation cancelled.")
        } catch { self.error = error.localizedDescription; status = nil; throw error }
    }

    func choosePreview() async throws {
        try requireIdle()
        busy = true
        onChange?()
        defer { busy = false; cancelOperation = nil; onChange?() }
        guard let package = await restoreSource() else { return }
        let scoped = package.startAccessingSecurityScopedResource()
        defer { if scoped { package.stopAccessingSecurityScopedResource() } }
        status = String(localized: "Validating the backup and checking conflicts…")
        error = nil
        preview = nil
        selectedPackage = nil
        do {
            let preferences = try WallpaperBackupPreferences(defaults: defaults, domainName: domainName)
            let service = service
            preview = try await run { try service.preview(package: package, preferences: preferences) }
            selectedPackage = package
            status = String(localized: "Review the conflicts and missing resources before confirming. Restore takes effect at the next launch.")
        } catch is CancellationError {
            status = String(localized: "Backup operation cancelled.")
        } catch { self.error = error.localizedDescription; status = nil; throw error }
    }

    func stageRestore(policy: WallpaperBackupConflictPolicy) async throws {
        try requireIdle()
        guard let preview, let package = selectedPackage else {
            throw WallpaperBackupFailure(message: String(localized: "Preview a backup before confirming restore."))
        }
        busy = true
        status = String(localized: "Staging the confirmed restore…")
        error = nil
        onChange?()
        defer { busy = false; cancelOperation = nil; pendingRestore = service.pendingRestore; onChange?() }
        let scoped = package.startAccessingSecurityScopedResource()
        defer { if scoped { package.stopAccessingSecurityScopedResource() } }
        do {
            let service = service
            try await run { try service.stageRestore(package: package, preview: preview, policy: policy) }
            status = String(localized: "Restore is ready for the next launch. Current wallpapers and settings have not changed.")
        } catch is CancellationError {
            status = String(localized: "Backup operation cancelled.")
        } catch { self.error = error.localizedDescription; status = nil; throw error }
    }

    func cancel() { cancelOperation?() }

    func cancelRestore() throws {
        try requireIdle()
        try service.cancelPendingRestore()
        pendingRestore = false
        error = nil
        status = String(localized: "Pending restore cancelled. Current wallpapers and settings have not changed.")
        onChange?()
    }

    private func requireIdle() throws {
        guard !busy else {
            throw WallpaperBackupFailure(message: String(localized: "Another backup operation is already running."))
        }
    }

    private func run<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        let task = Task.detached(priority: .utility) { try operation() }
        cancelOperation = { task.cancel() }
        onChange?()
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }

    private static func chooseExportDestination() async -> URL? {
        let panel = NSSavePanel()
        panel.title = String(localized: "Export local backup")
        panel.nameFieldStringValue = "WallpaperMachine-\(Date().formatted(.iso8601.year().month().day())).wmbackup"
        panel.allowedContentTypes = [UTType(exportedAs: WallpaperBackupService.packageTypeIdentifier, conformingTo: .package)]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.treatsFilePackagesAsDirectories = false
        return await withCheckedContinuation { continuation in
            panel.begin { result in continuation.resume(returning: result == .OK ? panel.url : nil) }
        }
    }

    private static func chooseRestoreSource() async -> URL? {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Preview local backup")
        panel.message = String(localized: "Choose a .wmbackup package. No current settings will change until you confirm and launch the app again.")
        panel.allowedContentTypes = [UTType(exportedAs: WallpaperBackupService.packageTypeIdentifier, conformingTo: .package)]
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        return await withCheckedContinuation { continuation in
            panel.begin { result in continuation.resume(returning: result == .OK ? panel.url : nil) }
        }
    }
}
