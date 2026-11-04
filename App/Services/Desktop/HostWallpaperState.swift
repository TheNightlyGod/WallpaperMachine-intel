import Foundation

/// The content lifecycle of one host-owned surface, separate from its assignment.
struct HostWallpaperState: Equatable, Sendable {
    enum Kind: String, Sendable { case web, nativeVideo }
    enum Phase: String, Sendable { case loading, ready, failed, closed }

    var kind: Kind
    var displayID: UInt32
    var wallpaperID: String
    var startupRevision: UInt64
    var nativeAdmissionKey: UInt64?
    var phase: Phase
    var message: String?
    /// The host can retry the current failed surface without rebuilding its assignment.
    var canRetry = false

    var key: String { Self.key(kind: kind, displayID: displayID) }

    /// The key `BridgeStore.hostWallpaperStates` keeps the state of `kind`'s surface on a display by.
    static func key(kind: Kind, displayID: UInt32) -> String { "\(kind.rawValue):\(displayID)" }
}
