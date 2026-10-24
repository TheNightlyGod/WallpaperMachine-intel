import Foundation
import Observation

/// Settings › Storage › Library location: where the library and the downloads are, the copy of a
/// move being prepared, and the move that waits for the next launch (`StorageMoveService`).
@MainActor
@Observable
final class StorageLocationStore {
    /// Where the library and the downloads are in this run. A move changes it only at a launch.
    let current: URL
    /// Whether that is WallpaperMachine's own folder on this Mac.
    let isOnThisMac: Bool
    private(set) var pending: StorageMoveService.Pending?
    /// The bytes copied so far while a move is being prepared, nil otherwise.
    private(set) var copiedBytes: Int64?
    private(set) var totalBytes: Int64 = 0
    /// Why the last move failed: now, or at the launch that was to finish it.
    private(set) var error: String?
    @ObservationIgnored private let service: StorageMoveService
    @ObservationIgnored private var cancelCopy: (() -> Void)?

    init(service: StorageMoveService = .init(), resolution: StorageLocation.Resolution = ClientPaths.storageResolution) {
        self.service = service
        switch resolution {
        case .support:
            current = service.support
            isOnThisMac = true
        case .chosen(let url):
            current = url
            isOnThisMac = false
        case .unavailable(let location):
            current = location?.url ?? service.support
            isOnThisMac = false
        }
        pending = service.pending
        // Said in this run's Settings, then forgotten: the library stayed where it was.
        error = service.lastFailure
        service.dismissFailure()
    }

    var isCopying: Bool { copiedBytes != nil }

    /// Checks a move into `parent` (nil: back to this Mac) without changing anything.
    func plan(moveTo parent: URL?) async throws -> StorageMoveService.Plan {
        let service = service
        return try await Task.detached(priority: .userInitiated) { try service.plan(moveTo: parent) }.value
    }

    /// Copies what `plan` moves and records the move for the next launch. Cancelling stops the copy
    /// and removes it.
    func move(_ plan: StorageMoveService.Plan) async throws {
        guard !isCopying else {
            throw StorageMoveError(String(localized: "The wallpaper library is already being copied."))
        }
        error = nil
        totalBytes = plan.bytes
        copiedBytes = 0
        defer {
            copiedBytes = nil
            cancelCopy = nil
            pending = service.pending
        }
        let service = service
        let task = Task.detached(priority: .utility) { [weak self] in
            try service.prepare(plan) { bytes in
                Task { @MainActor in
                    if self?.copiedBytes != nil { self?.copiedBytes = bytes }
                }
            }
        }
        cancelCopy = { task.cancel() }
        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
            throw error
        }
    }

    func cancel() { cancelCopy?() }

    /// Forgets the move that waits for the next launch and removes its copy.
    func cancelPending() throws {
        guard !isCopying else { return }
        try service.cancelPending()
        pending = service.pending
        error = nil
    }
}
