import Darwin
import Foundation

/// How long the native backend may wait on a wallpaper's file, by where the
/// file lives.
///
/// A disk that has spun down, a share that stopped answering and an iCloud or
/// File Provider placeholder that has to be fetched first all take far longer
/// to read than a file on the internal drive, and none of them is a statement
/// about the content. A single fixed limit would either fail a healthy clip on
/// a sleeping disk or let a dead share hold the host for
/// minutes, so the limit follows the storage class.
///
/// Classification is a pure function of a handful of facts so the rule can be
/// tested without a volume; reading the facts is the only part that touches the
/// file system.
enum NativeVideoStoragePolicy {
    enum Location: String, Equatable, Sendable {
        case internalVolume
        case removableVolume
        case networkVolume
        /// A file the system may have to download first: an iCloud Drive or
        /// File Provider item, or a placeholder whose data was evicted.
        case dataless
        /// The volume's flags could not be read.
        case unknown

        /// Names the class in a log line and in a failure reason.
        var label: String {
            switch self {
            case .internalVolume: return "internal volume"
            case .removableVolume: return "removable volume"
            case .networkVolume: return "network volume"
            case .dataless: return "cloud-backed file"
            case .unknown: return "volume of unknown kind"
            }
        }
    }

    /// What the file system said about a file. `nil` means the value could not
    /// be read, which is deliberately different from `false`.
    struct Facts: Equatable, Sendable {
        var isInternal: Bool?
        var isLocal: Bool?
        var isUbiquitous: Bool?
        var isDataless: Bool

        init(
            isInternal: Bool? = nil, isLocal: Bool? = nil, isUbiquitous: Bool? = nil,
            isDataless: Bool = false
        ) {
            self.isInternal = isInternal
            self.isLocal = isLocal
            self.isUbiquitous = isUbiquitous
            self.isDataless = isDataless
        }
    }

    /// Order matters. A file that may need downloading is slow wherever the
    /// volume claims to be; after that a volume that is not local is a network
    /// volume. A flag that could not be read is never treated as "internal":
    /// being wrong in that direction hands a healthy clip to the other backend,
    /// while being wrong the other way only waits longer.
    static func classify(_ facts: Facts) -> Location {
        if facts.isDataless || facts.isUbiquitous == true { return .dataless }
        guard let isLocal = facts.isLocal else { return .unknown }
        if !isLocal { return .networkVolume }
        guard let isInternal = facts.isInternal else { return .unknown }
        return isInternal ? .internalVolume : .removableVolume
    }

    /// How long reading a file's track metadata may take before the host stops
    /// waiting for it. A sleeping external drive needs the middle value to
    /// spin up; a share or a download gets the longest.
    static func metadataProbeDeadline(_ location: Location) -> Duration {
        switch location {
        case .internalVolume: return .seconds(8)
        case .removableVolume, .unknown: return .seconds(30)
        case .networkVolume, .dataless: return .seconds(60)
        }
    }

    /// How long a clip may take to show its first frame once the player has it.
    /// The same classes, with more room because decoding follows the read.
    static func firstFrameDeadline(_ location: Location) -> Duration {
        switch location {
        case .internalVolume: return .seconds(10)
        case .removableVolume, .unknown: return .seconds(30)
        case .networkVolume, .dataless: return .seconds(90)
        }
    }

    /// Reads the facts. Blocking: `stat(2)` on a volume that has stopped
    /// answering does not return, so this must never run on the main actor or
    /// the cooperative pool. `location(of:)` is the bounded way in.
    nonisolated static func facts(of url: URL) -> Facts {
        var facts = Facts()
        let keys: Set<URLResourceKey> = [
            .volumeIsInternalKey, .volumeIsLocalKey, .isUbiquitousItemKey,
        ]
        if let values = try? url.resourceValues(forKeys: keys) {
            facts.isInternal = values.volumeIsInternal
            facts.isLocal = values.volumeIsLocal
            facts.isUbiquitous = values.isUbiquitousItem
        }
        // `stat` does not materialise a dataless file, so asking is free.
        var info = stat()
        if stat(url.path, &info) == 0 {
            facts.isDataless = info.st_flags & UInt32(SF_DATALESS) != 0
        }
        return facts
    }

    /// The storage class of a file, read off the main actor and given up on
    /// after `limit`. A read that does not return is a volume that is not
    /// answering, so it is reported as `.unknown` and the caller keeps its own
    /// bound. The blocked read is left on a dispatch thread rather than a
    /// cooperative one: a few stuck volumes must not be able to starve every
    /// other piece of concurrent work.
    @MainActor
    static func location(
        of url: URL,
        within limit: Duration = .seconds(2),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        read: @escaping @Sendable (URL) -> Facts = { NativeVideoStoragePolicy.facts(of: $0) }
    ) async -> Location {
        let outcome = await NativeVideoDeadline.race(limit, sleep: sleep) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Location, Never>) in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: classify(read(url)))
                }
            }
        }
        if case let .value(location) = outcome { return location }
        return .unknown
    }
}
