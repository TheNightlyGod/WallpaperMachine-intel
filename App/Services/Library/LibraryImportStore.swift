import Foundation
import Observation

/// Runs one library import at a time and keeps its progress and last report. It belongs to the
/// app rather than to the control panel's page, so an import started from the panel, from
/// Finder's Open With or from a drop on the Dock icon runs to the end whether or not the panel
/// stays open.
@MainActor
@Observable
final class LibraryImportStore {
    private(set) var isBusy = false
    private(set) var status = ""
    private(set) var report: WallpaperImportService.Report?
    /// Why the last import stopped early. The next import, or the user dismissing it, clears it.
    private(set) var failure: String?
    /// Rescans the library once the files are in. Set by the app delegate once the bridge exists;
    /// nil only in tests that never import.
    @ObservationIgnored var refreshLibrary: (@MainActor () async throws -> Void)?
    /// Loads the files of a project an import replaced afresh on every display showing it, which
    /// would otherwise keep what it had loaded. Called once for each replaced id, in turn, once
    /// the library has been rescanned; a failure is the caller's to log.
    @ObservationIgnored var reloadReplaced: (@MainActor (String) async -> Void)?
    @ObservationIgnored private var task: Task<Void, Never>?
    /// The files are in and the import is only rescanning and reloading, on the bridge.
    @ObservationIgnored private var isSettling = false
    @ObservationIgnored private var isShuttingDown = false
    @ObservationIgnored private let importer: WallpaperImportService
    @ObservationIgnored private let library: URL

    init(importer: WallpaperImportService = WallpaperImportService(), library: URL = ClientPaths.libraryURL) {
        self.importer = importer
        self.library = library
    }

    /// Starts importing `sources`. Throws when an import is already running; an empty list
    /// starts nothing.
    func start(_ sources: [URL], duplicates: WallpaperImportService.DuplicatePolicy) throws {
        guard task == nil else {
            throw WallpaperActionError(message: String(localized: "An import is already running."))
        }
        guard !sources.isEmpty else { return }
        isBusy = true
        failure = nil
        report = nil
        status = String(localized: "Preparing import…")
        task = Task { [weak self] in await self?.run(sources, duplicates: duplicates) }
    }

    func cancel() {
        guard let task else { return }
        task.cancel()
        status = String(localized: "Cancelling…")
    }

    /// Stops the import and waits until it has left nothing half done in the library. The
    /// rescan and the reloads that follow are not waited for: they run on the bridge, a reload
    /// can last as long as a scene takes to load, and a quit only has a shared budget for all of
    /// its stages. None that has not begun is started, because the app is exiting and the next
    /// launch scans the library and loads what the displays show afresh.
    func shutdown() async {
        isShuttingDown = true
        guard let running = task, !isSettling else { return }
        running.cancel()
        await running.value
    }

    func dismissFailure() { failure = nil }

    private func run(_ sources: [URL], duplicates: WallpaperImportService.DuplicatePolicy) async {
        defer {
            task = nil
            isSettling = false
            isBusy = false
        }
        do {
            let report = try await importer.importItems(sources, into: library, duplicates: duplicates) {
                [weak self] status in
                guard let self else { return }
                await MainActor.run { self.status = status }
            }
            self.report = report
            if !isShuttingDown { try await settle(report) }
            status = report.cancelled ? String(localized: "Import cancelled") : String(localized: "Import complete")
        } catch {
            failure = error.localizedDescription
            status = String(localized: "Import could not finish")
        }
    }

    /// Brings the rest of the app up to date with the files an import put in place: rescans the
    /// library, then reloads each replaced project on the displays showing it.
    private func settle(_ report: WallpaperImportService.Report) async throws {
        isSettling = true
        if let refreshLibrary {
            // Its own task, so cancelling the import cannot also abandon the rescan that
            // makes what did arrive appear.
            try await Task { @MainActor in try await refreshLibrary() }.value
        }
        guard let reloadReplaced else { return }
        for id in report.replacedIDs {
            guard !isShuttingDown else { break }
            // The files are already replaced, so a cancel must not leave a display on the old ones.
            await Task { @MainActor in await reloadReplaced(id) }.value
        }
    }
}
