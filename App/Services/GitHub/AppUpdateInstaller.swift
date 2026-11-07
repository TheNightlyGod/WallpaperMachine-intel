import AppKit
import Darwin
import Foundation
import Security

protocol AppUpdateInstallationTask: Sendable {
    /// Returns true only once the helper can no longer replace or reopen the app.
    func cancel() async -> Bool
}

protocol AppUpdateInstalling: Sendable {
    var canInstallInPlace: Bool { get }
    func prepareInstallation(archive: URL) async throws -> URL
    func prepareInstallation(archive: URL, release: GitHubRelease) async throws -> URL
    func discardPreparation(_ extractedApp: URL) async
    func install(extractedApp: URL, replacing destination: URL) throws -> any AppUpdateInstallationTask
}

struct AppUpdateInstaller: AppUpdateInstalling, @unchecked Sendable {
    let currentAppURL: URL
    let fileManager: FileManager
    /// What a downloaded copy's signature must satisfy; tests pass one an ad-hoc copy meets.
    let signingRequirement: String
    /// The running version; a downloaded copy must be newer.
    let currentVersion: String

    init(currentAppURL: URL = Bundle.main.bundleURL, fileManager: FileManager = .default,
         signingRequirement: String = AppUpdateConfiguration.signingRequirement,
         currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") {
        self.currentAppURL = currentAppURL
        self.fileManager = fileManager
        self.signingRequirement = signingRequirement
        self.currentVersion = currentVersion
    }

    var canInstallInPlace: Bool {
        Self.isInstallableLocation(currentAppURL) && Self.canReplace(currentAppURL, fileManager: fileManager)
    }

    static func isInstallableLocation(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let applications = "/Applications/"
        let userApplications = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true).standardizedFileURL.path + "/"
        return path.hasPrefix(applications) || path.hasPrefix(userApplications)
    }

    /// The restart-install renames the bundle aside inside its folder and moves the new copy
    /// in, so this user must be able to write both. A standard account running a copy an
    /// administrator installed gets the manual drag-to-Applications path instead of an
    /// install that cannot finish after the app has already quit.
    static func canReplace(_ url: URL, fileManager: FileManager = .default) -> Bool {
        let app = url.standardizedFileURL
        return fileManager.isWritableFile(atPath: app.deletingLastPathComponent().path)
            && fileManager.isWritableFile(atPath: app.path)
    }

    /// Copies the app out of the downloaded disk image into a private work directory and
    /// validates the copy, its signature included. The image is mounted invisibly and
    /// read-only, and is always detached before this returns or throws.
    func prepareInstallation(archive: URL) async throws -> URL {
        try await AppUpdatePreparationWorker().prepare(
            archive: archive, root: fileManager.temporaryDirectory, signingRequirement: signingRequirement,
            currentVersion: currentVersion)
    }

    func prepareInstallation(archive: URL, release: GitHubRelease) async throws -> URL {
        try await AppUpdatePreparationWorker().prepare(
            archive: archive, root: fileManager.temporaryDirectory, signingRequirement: signingRequirement,
            currentVersion: currentVersion, release: release)
    }

    func discardPreparation(_ extractedApp: URL) async {
        let work = extractedApp.deletingLastPathComponent()
        guard work.lastPathComponent.hasPrefix("mwe-update-"),
              work.deletingLastPathComponent().standardizedFileURL == fileManager.temporaryDirectory.standardizedFileURL
        else { return }
        await AppUpdatePreparationWorker().discard(work)
    }

    fileprivate static func prepare(archive: URL, root: URL, signingRequirement: String, currentVersion: String) throws -> URL {
        try Task.checkCancellation()
        let fileManager = FileManager.default
        let work = root.appendingPathComponent("mwe-update-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        do {
            let app = try Self.copyApplication(fromDiskImage: archive, into: work)
            try Self.validate(app)
            try Self.verifySignature(of: app, requirement: signingRequirement)
            try Self.verifyNewer(app, than: currentVersion)
            try Task.checkCancellation()
            return app
        } catch {
            try? fileManager.removeItem(at: work)
            throw error
        }
    }

    func install(extractedApp: URL, replacing destination: URL) throws -> any AppUpdateInstallationTask {
        guard canInstallInPlace else {
            throw AppUpdateIssue(code: .permission, detail: String(localized: "The updater doesn't have permission to install this update."))
        }
        let cancellation = fileManager.temporaryDirectory.appendingPathComponent("mwe-install-cancel-\(UUID().uuidString)")
        let process = try Self.startReplacement(after: ProcessInfo.processInfo.processIdentifier,
            source: extractedApp, destination: destination, cancellation: cancellation, fileManager: fileManager)
        return AppUpdateProcessTask(process: process, cancellation: cancellation)
    }

    /// Starts the detached script that swaps the app once `pid` exits. The new copy is
    /// completed beside the old one before either is moved, and whichever copy is in place
    /// when the script stops is reopened, so a failure relaunches the previous version
    /// instead of leaving no app behind. `opener` is `open`; tests pass a recorder.
    @discardableResult
    static func startReplacement(after pid: Int32, source: URL, destination: URL,
                                 opener: String = "/usr/bin/open", cancellation: URL? = nil,
                                 fileManager: FileManager = .default) throws -> Process {
        // The lock stays on an open file description inherited as stdin. A
        // killed helper releases it automatically; never unlink the lock file,
        // since a second inode would let two replacements own the same target.
        let lock = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).update.lock")
        let descriptor = Darwin.open(lock.path, O_CREAT | O_RDWR | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw verificationIssue }
        let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? input.close() }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw AppUpdateIssue(code: .unknown, detail: String(localized: "Another update installation is still running."))
        }
        let script = fileManager.temporaryDirectory.appendingPathComponent("mwe-install-\(UUID().uuidString).sh")
        let cancellation = cancellation ?? script.appendingPathExtension("cancel")
        let contents = """
        #!/bin/bash
        set -uo pipefail
        pid="$1"
        src="$2"
        dst="$3"
        opener="$4"
        cancel="$5"
        trap '/bin/rm -f "$cancel" "$0"' EXIT
        while kill -0 "$pid" 2>/dev/null; do
            if [ -e "$cancel" ]; then exit 0; fi
            sleep 0.2
        done
        sleep 0.4
        if [ -e "$cancel" ]; then exit 0; fi
        staged="$(dirname "$dst")/.$(basename "$dst").update-$$"
        previous="$(dirname "$dst")/.$(basename "$dst").previous-$$"
        if /usr/bin/ditto "$src" "$staged" && /bin/mv "$dst" "$previous"; then
            if /bin/mv "$staged" "$dst"; then
                /bin/rm -rf "$previous"
            else
                /bin/mv "$previous" "$dst"
            fi
        fi
        /bin/rm -rf "$staged"
        /usr/bin/xattr -dr com.apple.quarantine "$dst" 2>/dev/null
        "$opener" "$dst"
        /bin/rm -rf "$(dirname "$src")"
        """
        try contents.write(to: script, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, String(pid), source.path, destination.path, opener, cancellation.path]
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
            try? fileManager.removeItem(at: script)
            throw error
        }
        return process
    }

    static func copyApplication(fromDiskImage image: URL, into work: URL) throws -> URL {
        let mountPoint = work.appendingPathComponent("mount", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        } catch {
            throw verificationIssue
        }
        defer { detach(mountPoint) }
        try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mountPoint.path, image.path])
        let source = try findApplication(in: mountPoint)
        let copy = work.appendingPathComponent(AppUpdateConfiguration.applicationName, isDirectory: true)
        try run("/usr/bin/ditto", ["--noqtn", source.path, copy.path])
        return copy
    }

    /// Detaches only a mounted volume root, so a failed attach never hands `hdiutil` the
    /// path of a plain directory on the volume that holds the work directory.
    static func detach(_ mountPoint: URL) {
        guard isVolumeRoot(mountPoint) else { return }
        if (try? run("/usr/bin/hdiutil", ["detach", mountPoint.path], cancellable: false)) == nil {
            try? run("/usr/bin/hdiutil", ["detach", "-force", mountPoint.path], cancellable: false)
        }
    }

    private static func isVolumeRoot(_ url: URL) -> Bool {
        let fresh = URL(fileURLWithPath: url.path, isDirectory: true)
        return (try? fresh.resourceValues(forKeys: [.isVolumeKey]).isVolume) == true
    }

    private static func run(_ executable: String, _ arguments: [String], cancellable: Bool = true) throws {
        if cancellable { try Task.checkCancellation() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            while process.isRunning {
                if cancellable && Task.isCancelled {
                    process.terminate()
                    process.waitUntilExit()
                    throw CancellationError()
                }
                Thread.sleep(forTimeInterval: 0.02)
            }
        } catch {
            if error is CancellationError { throw error }
            throw verificationIssue
        }
        if cancellable { try Task.checkCancellation() }
        guard process.terminationStatus == 0 else { throw verificationIssue }
    }

    /// Finds the single app in `root` without following symbolic links, so the disk
    /// image's `Applications` link is never traversed and a linked app never counts.
    static func findApplication(in root: URL) throws -> URL {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw verificationIssue
        }
        var found: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                enumerator.skipDescendants()
                continue
            }
            if url.lastPathComponent == AppUpdateConfiguration.applicationName {
                found.append(url.standardizedFileURL)
                enumerator.skipDescendants()
            }
        }
        guard found.count == 1 else {
            throw verificationIssue
        }
        return found[0]
    }

    private static var verificationIssue: AppUpdateIssue {
        AppUpdateIssue(code: .verification, detail: String(localized: "The update couldn't be verified, so it wasn't installed."))
    }

    static func validate(_ app: URL) throws {
        let info = app.appendingPathComponent("Contents/Info.plist")
        guard let values = NSDictionary(contentsOf: info) as? [String: Any],
              let identifier = values["CFBundleIdentifier"] as? String,
              identifier == AppUpdateConfiguration.bundleIdentifier
        else {
            throw AppUpdateIssue(code: .verification, detail: String(localized: "The update couldn't be verified, so it wasn't installed."))
        }
        let executable = app.appendingPathComponent("Contents/MacOS/WallpaperMachine")
        guard FileManager.default.isReadableFile(atPath: executable.path) else {
            throw AppUpdateIssue(code: .verification, detail: String(localized: "The update couldn't be verified, so it wasn't installed."))
        }
    }

    /// Refuses a copy whose signature is missing, broken anywhere in the bundle, or not made
    /// by one of the release signers. The digest proves the image is the one the release lists;
    /// this proves who built it, so a release asset someone replaced cannot install itself.
    static func verifySignature(of app: URL, requirement: String) throws {
        var code: SecStaticCode?
        var compiled: SecRequirement?
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(requirement as CFString, [], &compiled) == errSecSuccess, let compiled,
              SecStaticCodeCheckValidity(code, flags, compiled) == errSecSuccess
        else { throw verificationIssue }
    }

    /// Refuses a copy that is not newer than the running one. A genuine older release passes
    /// the signature check, so this is what stops a mirror relaying it as the latest from
    /// rolling the app back.
    static func verifyTarget(_ app: URL, release: GitHubRelease, systemVersion: String = AppUpdatePolicy.systemVersion) throws {
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
        guard let version = info?["CFBundleShortVersionString"] as? String,
              SemanticVersion(version) == release.version else { throw verificationIssue }
        guard let minimum = info?["LSMinimumSystemVersion"] as? String,
              let required = UpdateSystemVersion(minimum), let current = UpdateSystemVersion(systemVersion),
              current >= required,
              Bundle(url: app)?.executableArchitectures?.contains(NSNumber(value: CPU_TYPE_ARM64)) == true,
              AppUpdatePolicy.supports(release, systemVersion: systemVersion)
        else { throw AppUpdateIssue(code: .incompatible, detail: "Incompatible signed application") }
        if let declared = release.minimumSystemVersion, UpdateSystemVersion(declared) != required {
            throw verificationIssue
        }
    }

    static func verifyNewer(_ app: URL, than currentVersion: String) throws {
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
        guard let candidate = (info?["CFBundleShortVersionString"] as? String).flatMap(SemanticVersion.init),
              let current = SemanticVersion(currentVersion), candidate > current
        else { throw verificationIssue }
    }
}

private actor AppUpdatePreparationWorker {
    func prepare(archive: URL, root: URL, signingRequirement: String, currentVersion: String) throws -> URL {
        try AppUpdateInstaller.prepare(archive: archive, root: root, signingRequirement: signingRequirement,
                                       currentVersion: currentVersion)
    }
    func prepare(archive: URL, root: URL, signingRequirement: String, currentVersion: String,
                 release: GitHubRelease) throws -> URL {
        let app = try AppUpdateInstaller.prepare(archive: archive, root: root, signingRequirement: signingRequirement,
                                                currentVersion: currentVersion)
        do {
            try AppUpdateInstaller.verifyTarget(app, release: release)
            return app
        } catch {
            discard(app.deletingLastPathComponent())
            throw error
        }
    }
    func discard(_ work: URL) {
        try? FileManager.default.removeItem(at: work)
    }
}

extension AppUpdateInstalling {
    func prepareInstallation(archive: URL, release: GitHubRelease) async throws -> URL {
        try await prepareInstallation(archive: archive)
    }
    func discardPreparation(_ extractedApp: URL) async {}
}

final class AppUpdateProcessTask: AppUpdateInstallationTask, @unchecked Sendable {
    private let process: Process
    private let cancellation: URL

    init(process: Process, cancellation: URL) {
        self.process = process
        self.cancellation = cancellation
    }

    func cancel() async -> Bool {
        guard process.isRunning else { return true }
        do { try Data().write(to: cancellation, options: .atomic) } catch { return false }
        // Cancellation is cooperative while the helper is waiting for this app.
        // A timeout keeps ownership with the store, so retry cannot overlap it.
        for _ in 0..<100 {
            if !process.isRunning { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return !process.isRunning
    }
}
