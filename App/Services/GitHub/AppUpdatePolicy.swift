import Foundation

enum AppUpdateMode: String, CaseIterable, Sendable {
    case notify, download, automatic

    static let key = "WallpaperMachine.updates.mode"

    static func migrate(saved: String?, legacy: Bool?, freshInstall: Bool) -> Self {
        if let saved { return Self(rawValue: saved) ?? .notify }
        if let legacy { return legacy ? .automatic : .notify }
        return freshInstall ? .automatic : .notify
    }

    static func initialize(in defaults: UserDefaults, freshInstall: Bool) {
        let mode = migrate(saved: defaults.string(forKey: key),
                           legacy: defaults.object(forKey: AppUpdateStore.automaticKey) as? Bool,
                           freshInstall: freshInstall)
        defaults.set(mode.rawValue, forKey: key)
    }
}

struct UpdateSystemVersion: Comparable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ raw: String) {
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count else { return nil }
        major = numbers[0]
        minor = numbers.count > 1 ? numbers[1] : 0
        patch = numbers.count > 2 ? numbers[2] : 0
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

enum AppUpdatePolicy {
    static let checkInterval: TimeInterval = 6 * 60 * 60
    static let postponement: TimeInterval = 24 * 60 * 60

    struct InstallInput {
        var mode: AppUpdateMode
        var unattended: Bool
        var shuttingDown: Bool
        var onboardingComplete: Bool
        var canInstallInPlace: Bool
        var skipped: Bool
        var deferred: Bool
        var blocked: Bool
    }

    static func mayInstall(_ input: InstallInput) -> Bool {
        input.mode == .automatic && input.unattended && !input.shuttingDown
            && input.onboardingComplete && input.canInstallInPlace
            && !input.skipped && !input.deferred && !input.blocked
    }

    static var systemVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    static func supports(_ release: GitHubRelease, systemVersion: String = systemVersion,
                         architecture: String = "arm64") -> Bool {
        if let identifier = release.bundleIdentifier, identifier != AppUpdateConfiguration.bundleIdentifier { return false }
        if let architectures = release.architectures, !architectures.contains(architecture) { return false }
        if let minimum = release.minimumSystemVersion {
            guard let required = UpdateSystemVersion(minimum), let current = UpdateSystemVersion(systemVersion),
                  current >= required else { return false }
        }
        return true
    }
}
