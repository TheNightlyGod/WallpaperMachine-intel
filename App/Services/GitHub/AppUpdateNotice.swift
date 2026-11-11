import Foundation

struct AppUpdateNotice: Equatable, Sendable {
    enum Kind: Sendable { case available, downloading, verifying, ready, deferred, failed, installed }
    var kind: Kind
    var version: String
    var automatic: Bool
    var percent: Int = 0

    init(kind: Kind, version: String, automatic: Bool, percent: Int = 0) {
        self.kind = kind
        self.version = version
        self.automatic = automatic
        self.percent = percent
    }

    @MainActor
    init?(store: AppUpdateStore) {
        automatic = store.mode == .automatic && store.canInstallInPlace
        if let candidate = store.state.availableVersion {
            version = candidate
            switch store.state {
            case .downloading(_, _, let value, _, _, _):
                kind = store.isVerifyingDownload ? .verifying : .downloading
                percent = Int(value)
            case .preparing: kind = .verifying
            case .ready: kind = store.isDeferred ? .deferred : .ready
            case .error: kind = .failed
            default: kind = store.isDeferred ? .deferred : .available
            }
            if store.blockedAutomaticVersion == candidate { kind = .failed }
        } else if let installed = store.recentlyInstalledVersion {
            version = installed
            kind = .installed
        } else { return nil }
    }
}
