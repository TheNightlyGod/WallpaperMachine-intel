import Darwin
import Foundation
import Observation

struct SteamCMDSetupIssue: LocalizedError, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case invalidSelection, incompleteRuntime, network, invalidArchive, appleSiliconRequired
        case securityApprovalRequired, invalidSignature, updateFailed, timedOut, fileSystem
    }
    let kind: Kind
    let detail: String
    var errorDescription: String? { detail }
}

enum SteamCMDSetupState: Equatable {
    case idle, checking, downloading(received: Int64, expected: Int64?), extracting
    case validating, committing, ready, cancelled, failed(SteamCMDSetupIssue)
}

@MainActor
protocol SteamCMDDownloadActivity: AnyObject {
    var isRunning: Bool { get }
}

protocol SteamCMDProcessRunning: Sendable {
    func run(executable: URL, arguments: [String], workingDirectory: URL,
             environment: [String: String], onOutput: @escaping @Sendable (Data) -> Void) async throws -> Int32
}

/// Every invocation owns a process group, including shell children; returning means its leader was reaped.
struct SteamCMDProcessRunner: SteamCMDProcessRunning {
    func run(executable: URL, arguments: [String], workingDirectory: URL,
             environment: [String: String], onOutput: @escaping @Sendable (Data) -> Void) async throws -> Int32 {
        try Task.checkCancellation()
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { throw posixIssue(String(localized: "Create process output pipe"), errno) }
        defer { close(descriptors[0]); close(descriptors[1]) }
        _ = fcntl(descriptors[0], F_SETFL, O_NONBLOCK)
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        var result = posix_spawn_file_actions_init(&actions)
        guard result == 0 else { throw posixIssue(String(localized: "Initialize process actions"), result) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        result = posix_spawnattr_init(&attributes)
        guard result == 0 else { throw posixIssue(String(localized: "Initialize process attributes"), result) }
        defer { posix_spawnattr_destroy(&attributes) }
        func check(_ code: Int32) throws { if code != 0 { throw posixIssue(String(localized: "Configure child process"), code) } }
        try check(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)))
        try check(posix_spawnattr_setpgroup(&attributes, 0))
        try check(SteamCMDArchitecture.requireNative(&attributes))
        try check(posix_spawn_file_actions_addchdir_np(&actions, workingDirectory.path))
        try check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
        try check(posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO))
        try check(posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDERR_FILENO))
        try check(posix_spawn_file_actions_addclose(&actions, descriptors[0]))
        try check(posix_spawn_file_actions_addclose(&actions, descriptors[1]))
        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let envp = environment.keys.sorted().map { strdup("\($0)=\(environment[$0]!)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var pid: pid_t = 0
        result = argv.withUnsafeBufferPointer { args in
            envp.withUnsafeBufferPointer { env in
                posix_spawn(&pid, executable.path, &actions, &attributes, args.baseAddress!, env.baseAddress!)
            }
        }
        guard result == 0 else { throw posixIssue(String(localized: "Start \(executable.lastPathComponent)"), result) }
        // The parent does not need a writer. Keep the deferred close from closing a reused descriptor.
        close(descriptors[1])
        descriptors[1] = -1
        let started = ContinuousClock.now
        var lastOutput = started
        var cleaned = false
        var buffer = [UInt8](repeating: 0, count: 8192)
        func drain() {
            // Bound each drain so a noisy child cannot starve cancellation or the total deadline.
            for _ in 0..<32 {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptors[0], $0.baseAddress, $0.count) }
                guard count > 0 else { break }
                lastOutput = .now
                onOutput(Data(buffer.prefix(count)))
            }
        }
        do {
            while true {
                try Task.checkCancellation()
                drain()
                // Observe exit without reaping: reserve the leader PID until all group signals are sent.
                var information = siginfo_t()
                let waited = waitid(P_PID, id_t(pid), &information, WEXITED | WNOHANG | WNOWAIT)
                if waited == 0, information.si_pid == pid { break }
                if waited < 0, errno != EINTR {
                    let code = errno
                    // If another reaper took the leader, this PID is no longer ours to signal.
                    if code == ECHILD { cleaned = true }
                    throw posixIssue(String(localized: "Wait for child process"), code)
                }
                if started.duration(to: .now) > .seconds(1800) || lastOutput.duration(to: .now) > .seconds(300) {
                    throw SteamCMDSetupIssue(kind: .timedOut, detail: String(localized: "SteamCMD timed out. Check the connection and retry."))
                }
                try await Task.sleep(for: .milliseconds(40))
            }
            drain()
            let status = await Self.stopGroup(pid, leaderExited: true)
            cleaned = true
            try Task.checkCancellation()
            return (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        } catch {
            if !cleaned { _ = await Self.stopGroup(pid, leaderExited: false) }
            throw error
        }
    }

    private static func stopGroup(_ pid: pid_t, leaderExited: Bool) async -> Int32 {
        // An unstructured cleanup task deliberately does not inherit the cancelled caller's flag.
        await Task.detached(priority: .utility) {
            kill(-pid, SIGTERM)
            if !leaderExited {
                let deadline = ContinuousClock.now.advanced(by: .seconds(2))
                while kill(-pid, 0) == 0, ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(40))
                }
            }
            // The unreaped leader reserves this PID/PGID until after the final group signal.
            // A completed leader has no useful background work to leave running.
            kill(-pid, SIGKILL)
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0, errno == EINTR {}
            return status
        }.value
    }

    private func posixIssue(_ action: String, _ code: Int32) -> SteamCMDSetupIssue {
        SteamCMDSetupIssue(kind: .fileSystem, detail: String(localized: "\(action): \(String(cString: strerror(code)))"))
    }
}

@MainActor
@Observable
final class SteamCMDSetupStore {
    private(set) var selectedRuntime: SteamCMDRuntime?
    private(set) var state: SteamCMDSetupState = .idle
    private(set) var retainedCandidateURL: URL?
    var isBusy: Bool {
        if discarding { return true }
        return switch state {
        case .checking, .downloading, .extracting, .validating, .committing: true
        case .idle, .ready, .cancelled, .failed: false
        }
    }
    @ObservationIgnored private let downloader: any SteamCMDDownloadActivity
    @ObservationIgnored private let supportDirectory: URL
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let sessionConfiguration: URLSessionConfiguration
    @ObservationIgnored private let runtimeProvider: any SteamCMDRuntimeProviding
    @ObservationIgnored private let processRunner: any SteamCMDProcessRunning
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var discardOperation: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    private struct PendingInstallation: Codable, Equatable {
        /// `bootstrap` survives only to recognize candidates retained by the retired Intel-only
        /// bootstrap installer; native installations are always retained `complete`.
        enum Stage: String, Codable { case bootstrap, complete }
        let directory: String
        let device: UInt64
        let inode: UInt64
        var stage: Stage
        let replacingExisting: Bool
        var detail = ""
    }
    @ObservationIgnored private var pending: PendingInstallation?
    private var discarding = false
    private var pendingURL: URL { supportDirectory.appendingPathComponent("SteamCMDPending.json") }
    private static let preferenceKey = "WallpaperMachineSteamCMDPath"
    private var managedURL: URL { supportDirectory.appendingPathComponent("SteamCMD", isDirectory: true) }

    init(downloader: any SteamCMDDownloadActivity, supportDirectory: URL = ClientPaths.supportURL,
         defaults: UserDefaults = ClientPreferences.defaults, sessionConfiguration: URLSessionConfiguration = .ephemeral,
         runtimeProvider: any SteamCMDRuntimeProviding = SteamCMDRuntimeService(),
         processRunner: any SteamCMDProcessRunning = SteamCMDProcessRunner()) {
        self.downloader = downloader
        // Normalize only Apple's fixed system aliases, never a user-selected runtime symlink.
        let path = supportDirectory.path
        if path.hasPrefix("/var/") || path.hasPrefix("/tmp/") {
            self.supportDirectory = URL(fileURLWithPath: "/private" + path, isDirectory: true)
        } else {
            self.supportDirectory = supportDirectory
        }
        self.defaults = defaults
        self.sessionConfiguration = sessionConfiguration
        self.runtimeProvider = runtimeProvider
        self.processRunner = processRunner
        do {
            if let record = try readPending() {
                do {
                    _ = try stagingURL(for: record)
                    try Self.requireSafeDirectory(retainedRoot(record), mayBeMissing: false)
                    if record.stage == .bootstrap {
                        // Its next step was running Valve's Intel updater, which a native install
                        // never does; the next install starts over from the package manifest.
                        try removeStaging(record)
                    } else {
                        setPending(record)
                        state = .failed(pendingIssue(record))
                    }
                } catch {
                    // A dangling or substituted candidate cannot be resumed. Remove only the
                    // private record, never the path it supplied or a directory discovered through it.
                    if try readPending() == record { unlink(pendingURL.path) }
                    throw error
                }
            }
        } catch { state = .failed(Self.issue(error)) }
    }

    func refresh() async {
        guard !isBusy, !downloader.isRunning, !discarding else { return }
        begin(state: .checking) { store, token in
            defer {
                if let record = store.pending { store.state = .failed(store.pendingIssue(record)) }
            }
            if let explicit = store.defaults.string(forKey: Self.preferenceKey), !explicit.isEmpty {
                do {
                    let runtime = try await store.checkedRuntime(URL(fileURLWithPath: explicit))
                    try store.check(token)
                    store.selectedRuntime = runtime
                    store.state = .ready
                } catch {
                    try store.check(token)
                    store.selectedRuntime = nil
                    throw error
                }
                return
            }
            let candidates = [store.managedURL.appendingPathComponent("MacOS/steamcmd"),
                              store.managedURL.appendingPathComponent("steamcmd"),
                              URL(fileURLWithPath: "/opt/homebrew/bin/steamcmd"),
                              URL(fileURLWithPath: "/usr/local/bin/steamcmd"),
                              FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Steam/steamcmd.sh")]
            // An Intel-only copy is not usable, but saying so beats reporting nothing installed:
            // its reinstall offer is what moves the user to a native copy.
            var intelOnly: SteamCMDSetupIssue?
            for candidate in candidates {
                try store.check(token)
                do {
                    let runtime = try await store.checkedRuntime(candidate)
                    try store.check(token)
                    store.selectedRuntime = runtime
                    store.state = .ready
                    return
                } catch is CancellationError { throw CancellationError() }
                catch let issue as SteamCMDSetupIssue where issue.kind == .appleSiliconRequired {
                    if intelOnly == nil { intelOnly = issue }
                } catch { continue }
            }
            try store.check(token)
            store.selectedRuntime = nil
            if let intelOnly { throw intelOnly }
            store.state = .idle
        }
        await operation?.value
    }

    func selectExisting(at url: URL) {
        guard !isBusy, !downloader.isRunning, !discarding else { return }
        begin(state: .checking) { store, token in
            let runtime = try await store.checkedRuntime(url)
            try store.check(token)
            store.defaults.set(runtime.executableURL.path, forKey: Self.preferenceKey)
            store.selectedRuntime = runtime
            store.state = .ready
        }
    }

    func install(replacingExisting: Bool = false) {
        guard !isBusy, !downloader.isRunning, !discarding else { return }
        if pending != nil { retryInstallation(); return }
        begin(state: .checking) { store, token in
            try await store.performInstall(replacingExisting: replacingExisting, token: token)
        }
    }

    func retryInstallation() {
        guard !isBusy, !downloader.isRunning, !discarding, let record = pending else { return }
        begin(state: .checking) { store, token in
            try await store.performRetained(record, token: token)
        }
    }

    func prepareApproval() async throws -> SteamCMDApprovalCandidate {
        guard !isBusy, !discarding, let record = pending,
              let approver = runtimeProvider as? any SteamCMDRuntimeApproving else { throw staleApprovalIssue() }
        let token = generation
        let root = try stagingURL(for: record).appendingPathComponent("runtime/MacOS", isDirectory: true)
        let candidate = try await approver.approvalCandidate(at: root)
        try check(token)
        guard !isBusy, !discarding, pending == record, candidate.rootURL == root else { throw staleApprovalIssue() }
        _ = try stagingURL(for: record)
        return candidate
    }

    func approveRetainedCandidate(_ candidate: SteamCMDApprovalCandidate) {
        guard !isBusy, !downloader.isRunning, !discarding else { return }
        guard let record = pending, candidate.rootURL == retainedCandidateURL,
              let approver = runtimeProvider as? any SteamCMDRuntimeApproving else {
            state = .failed(staleApprovalIssue())
            return
        }
        begin(state: .checking) { store, token in
            defer { if Task.isCancelled { try? store.removeStaging(record) } }
            _ = try store.stagingURL(for: record)
            let current = try await approver.approvalCandidate(at: candidate.rootURL)
            try store.check(token)
            guard store.pending == record, current == candidate else { throw store.staleApprovalIssue() }
            try await approver.approve(candidate)
            try store.check(token)
            try await store.performRetained(record, token: token)
        }
    }

    func discardRetainedCandidate() {
        guard !discarding, state != .committing, let record = pending else { return }
        discarding = true
        // Shutdown must also wait for this explicit deletion, not only the cancelled process owner.
        let active = operation
        active?.cancel()
        discardOperation = Task { @MainActor in
            await active?.value
            defer { discarding = false; discardOperation = nil }
            do {
                if pending?.directory == record.directory { try removeStaging(record) }
                state = selectedRuntime == nil ? .idle : .ready
            } catch { state = .failed(Self.issue(error)) }
        }
    }

    private func staleApprovalIssue() -> SteamCMDSetupIssue {
        SteamCMDSetupIssue(kind: .invalidSelection, detail: String(localized: "The retained SteamCMD candidate changed. Review it again before approving."))
    }

    func cancel() {
        guard state != .committing else { return }
        if isBusy { operation?.cancel() }
    }

    func shutdown() async {
        if isBusy { cancel() }
        await operation?.value
        await discardOperation?.value
    }

    private func begin(state newState: SteamCMDSetupState,
                       body: @escaping @MainActor (SteamCMDSetupStore, UUID) async throws -> Void) {
        let token = UUID()
        generation = token
        state = newState
        operation = Task {
            defer { if generation == token { operation = nil } }
            do { try await body(self, token) }
            catch {
                guard generation == token else { return }
                // Do not leave an externally deleted or replaced old runtime available after failure.
                if let old = selectedRuntime {
                    let provider = runtimeProvider
                    do {
                        try await Task.detached(priority: .utility) {
                            let runtime = try provider.resolve(executable: old.executableURL)
                            try await provider.validate(at: runtime.rootURL)
                        }.value
                    }
                    catch { selectedRuntime = nil }
                }
                if error is CancellationError || Task.isCancelled { state = .cancelled }
                else { state = .failed(Self.issue(error)) }
            }
        }
    }

    private func check(_ token: UUID) throws {
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
    }

    private func checkedRuntime(_ executable: URL) async throws -> SteamCMDRuntime {
        let runtime = try runtimeProvider.resolve(executable: executable)
        try await runtimeProvider.validate(at: runtime.rootURL)
        return runtime
    }

    private func setPending(_ record: PendingInstallation?) {
        pending = record
        retainedCandidateURL = record.map {
            supportDirectory.appendingPathComponent($0.directory, isDirectory: true)
                .appendingPathComponent("runtime/MacOS", isDirectory: true)
        }
    }

    private func pendingIssue(_ record: PendingInstallation) -> SteamCMDSetupIssue {
        SteamCMDSetupIssue(kind: .securityApprovalRequired, detail: record.detail)
    }

    private func stagingURL(for record: PendingInstallation) throws -> URL {
        let prefix = ".steamcmd-setup-"
        guard record.directory.hasPrefix(prefix),
              let identifier = UUID(uuidString: String(record.directory.dropFirst(prefix.count))),
              record.directory == prefix + identifier.uuidString else { throw staleApprovalIssue() }
        let staging = supportDirectory.appendingPathComponent(record.directory, isDirectory: true)
        try Self.requireSafeDirectory(staging, mayBeMissing: false)
        var info = stat()
        guard lstat(staging.path, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o777 == 0o700,
              UInt64(info.st_dev) == record.device, UInt64(info.st_ino) == record.inode else { throw staleApprovalIssue() }
        return staging
    }

    private func readPending() throws -> PendingInstallation? {
        try Self.requireSafeDirectory(supportDirectory, mayBeMissing: true)
        let descriptor = open(pendingURL.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw staleApprovalIssue()
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o777 == 0o600,
              info.st_size > 0, info.st_size <= 16 * 1024 else { throw staleApprovalIssue() }
        let data = try handle.read(upToCount: 16 * 1024 + 1) ?? Data()
        guard data.count == Int(info.st_size) else { throw staleApprovalIssue() }
        return try JSONDecoder().decode(PendingInstallation.self, from: data)
    }

    private func persistPending(_ record: PendingInstallation) throws {
        _ = try stagingURL(for: record)
        try Self.requireSafeDirectory(retainedRoot(record), mayBeMissing: false)
        if let existing = try readPending(), existing.directory != record.directory { throw staleApprovalIssue() }
        let temporary = supportDirectory.appendingPathComponent(".steamcmd-pending-\(UUID().uuidString)")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw staleApprovalIssue() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); unlink(temporary.path) }
        try handle.write(contentsOf: JSONEncoder().encode(record))
        try handle.synchronize()
        guard rename(temporary.path, pendingURL.path) == 0 else { throw staleApprovalIssue() }
        setPending(record)
    }

    private func retainedRoot(_ record: PendingInstallation) -> URL {
        supportDirectory.appendingPathComponent(record.directory, isDirectory: true)
            .appendingPathComponent("runtime/MacOS", isDirectory: true)
    }

    private func removeStaging(_ record: PendingInstallation) throws {
        // Never resolve a supplied path or follow a substituted staging directory during deletion.
        if let existing = try readPending(), existing.directory == record.directory {
            guard existing.device == record.device, existing.inode == record.inode,
                  unlink(pendingURL.path) == 0 else { throw staleApprovalIssue() }
        }
        if pending?.directory == record.directory { setPending(nil) }
        let staging = try stagingURL(for: record)
        try FileManager.default.removeItem(at: staging)
    }

    private func performInstall(replacingExisting: Bool, token: UUID) async throws {
        let fm = FileManager.default
        try Self.requireSafeDirectory(supportDirectory, mayBeMissing: true)
        try fm.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        try Self.requireSafeDirectory(managedURL, mayBeMissing: true)
        if fm.fileExists(atPath: managedURL.path), !replacingExisting {
            throw SteamCMDSetupIssue(kind: .invalidSelection, detail: String(localized: "SteamCMD already exists. Confirm Reinstall SteamCMD before replacing it."))
        }
        let staging = supportDirectory.appendingPathComponent(".steamcmd-setup-\(UUID().uuidString)", isDirectory: true)
        guard mkdir(staging.path, 0o700) == 0 else {
            throw SteamCMDSetupIssue(kind: .fileSystem, detail: String(localized: "Could not create a private SteamCMD installation directory."))
        }
        var info = stat()
        guard lstat(staging.path, &info) == 0 else { throw staleApprovalIssue() }
        let record = PendingInstallation(directory: staging.lastPathComponent, device: UInt64(info.st_dev),
                                         inode: UInt64(info.st_ino), stage: .complete, replacingExisting: replacingExisting)
        var handedOff = false
        defer { if !handedOff { try? removeStaging(record) } }
        let container = staging.appendingPathComponent("runtime", isDirectory: true)
        let runtimeRoot = container.appendingPathComponent("MacOS", isDirectory: true)
        let home = staging.appendingPathComponent("home", isDirectory: true)
        let temporary = staging.appendingPathComponent("tmp", isDirectory: true)
        let downloads = staging.appendingPathComponent("packages", isDirectory: true)
        for directory in [runtimeRoot, home, temporary, downloads] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": home.path,
                           "TMPDIR": temporary.path + "/", "TERM": "dumb", "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"]
        state = .downloading(received: 0, expected: nil)
        // The manifest Valve's own updater reads lists the universal runtime's packages. Installing
        // them directly replaces running the 2020 Intel-only bootstrap under Rosetta to fetch them.
        let manifestFile = downloads.appendingPathComponent("steam_cmd_osx")
        _ = try await SteamCMDDownload(source: SteamCMDPackageManifest.url, destination: manifestFile,
                                       maximum: SteamCMDPackageManifest.maximumSize,
                                       configuration: sessionConfiguration).start()
        try check(token)
        let manifestData = try Data(contentsOf: manifestFile)
        let manifest = try SteamCMDPackageManifest(data: manifestData)
        AppLog.info("SteamCMD setup: Valve package manifest \(manifest.version), \(manifest.packages.count) packages, \(manifest.totalSize) bytes")
        let total = manifest.totalSize
        state = .downloading(received: 0, expected: total)
        var archives: [URL] = []
        var completed: Int64 = 0
        for package in manifest.packages {
            let archive = downloads.appendingPathComponent(package.file)
            let base = completed
            let digest = try await SteamCMDDownload(source: package.url, destination: archive, maximum: package.size,
                                                    expectedSize: package.size, configuration: sessionConfiguration) { [weak self] received, _ in
                Task { @MainActor in
                    // Updates hop to the main actor out of order; the total never runs backwards.
                    guard let self, self.generation == token, !Task.isCancelled,
                          case .downloading(let shown, _) = self.state, base + received > shown else { return }
                    self.state = .downloading(received: base + received, expected: total)
                }
            }.start()
            guard digest.sha256 == package.sha256, digest.sha1 == package.sha1 else {
                throw SteamCMDSetupIssue(kind: .invalidArchive, detail: String(localized: "The SteamCMD package \(package.name) does not match Valve’s published checksum. Nothing was installed."))
            }
            completed += package.size
            try check(token)
            archives.append(archive)
        }
        state = .extracting
        // Every package is listed and measured before any is extracted, so a later unsafe or
        // oversized package cannot leave a partial runtime behind.
        var entries: [String: Bool] = [:]
        var expanded: Int64 = 0
        var listingEnvironment = environment
        listingEnvironment["LC_ALL"] = "C"
        listingEnvironment["LANG"] = "C"
        for archive in archives {
            let listing = SteamCMDOutputBuffer(limit: 2 * 1024 * 1024)
            let listed = try await processRunner.run(executable: URL(fileURLWithPath: "/usr/bin/tar"),
                arguments: ["-t", "-f", archive.path], workingDirectory: staging, environment: listingEnvironment,
                onOutput: { listing.append($0) })
            guard listed == 0, !listing.overflowed else {
                throw SteamCMDSetupIssue(kind: .invalidArchive, detail: String(localized: "The SteamCMD archive could not be listed safely."))
            }
            try Self.validateListing(listing.data, entries: &entries)
            let sizes = SteamCMDOutputBuffer(limit: 2 * 1024 * 1024)
            let measured = try await processRunner.run(executable: URL(fileURLWithPath: "/usr/bin/tar"),
                arguments: ["-t", "-v", "--numeric-owner", "-f", archive.path], workingDirectory: staging,
                environment: listingEnvironment, onOutput: { sizes.append($0) })
            guard measured == 0, !sizes.overflowed else {
                throw SteamCMDSetupIssue(kind: .invalidArchive, detail: String(localized: "The SteamCMD archive's expanded size could not be checked safely."))
            }
            try Self.validateExpandedSizeListing(sizes.data, total: &expanded)
            try check(token)
        }
        for archive in archives {
            let diagnostics = SteamCMDOutputBuffer(limit: 16 * 1024)
            // Valve's zips separate some directory names with backslashes, as its updater expects.
            let extracted = try await processRunner.run(executable: URL(fileURLWithPath: "/usr/bin/tar"),
                arguments: ["-x", "-k", "-s", "|\\\\|/|g", "--no-same-owner", "--no-same-permissions", "--no-acls", "--no-fflags",
                            "--no-xattrs", "--no-mac-metadata", "-f", archive.path, "-C", runtimeRoot.path],
                workingDirectory: staging, environment: environment, onOutput: { diagnostics.append($0) })
            guard extracted == 0 else {
                throw SteamCMDSetupIssue(kind: .invalidArchive, detail: String(localized: "SteamCMD extraction failed. \(diagnostics.text)"))
            }
            try check(token)
        }
        // Kept beside the runtime, as Valve's updater does, so the installed version is on record.
        let packageRecord = runtimeRoot.appendingPathComponent("package", isDirectory: true)
        try Self.requireSafeDirectory(runtimeRoot, mayBeMissing: false)
        try fm.createDirectory(at: packageRecord, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try Self.requireSafeDirectory(packageRecord, mayBeMissing: false)
        try manifestData.write(to: packageRecord.appendingPathComponent("steam_cmd_osx.manifest"), options: .withoutOverwriting)
        try await Self.inspectAndQuarantine(runtimeRoot, byteLimit: 256 * 1024 * 1024)
        for path in ["steamcmd", "crashhandler.dylib", "steamconsole.dylib", "Frameworks/Breakpad.framework"] {
            guard fm.fileExists(atPath: runtimeRoot.appendingPathComponent(path).path) else {
                throw SteamCMDSetupIssue(kind: .invalidArchive, detail: String(localized: "Valve’s SteamCMD packages are missing \(path)."))
            }
        }
        handedOff = true
        try await performRetained(record, token: token)
    }

    private func performRetained(_ initial: PendingInstallation, token: UUID) async throws {
        var record = initial
        var retain = false
        defer { if !retain { try? removeStaging(record) } }
        do {
            let staging = try stagingURL(for: record)
            let container = staging.appendingPathComponent("runtime", isDirectory: true)
            let runtimeRoot = container.appendingPathComponent("MacOS", isDirectory: true)
            try Self.requireSafeDirectory(runtimeRoot, mayBeMissing: false)
            let home = staging.appendingPathComponent("home", isDirectory: true)
            let temporary = staging.appendingPathComponent("tmp", isDirectory: true)
            try Self.requireSafeDirectory(home, mayBeMissing: false)
            try Self.requireSafeDirectory(temporary, mayBeMissing: false)
            let environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": home.path,
                               "TMPDIR": temporary.path + "/", "TERM": "dumb", "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"]
            let diagnostics = SteamCMDOutputBuffer(limit: 16 * 1024)
            // Only a native installation is resumed; init discards retired bootstrap candidates.
            guard record.stage == .complete else { throw staleApprovalIssue() }
            state = .validating
            try await finishInstallation(record, staging: staging, container: container, runtimeRoot: runtimeRoot,
                                         environment: environment, diagnostics: diagnostics, token: token)
        } catch {
            if !Task.isCancelled, let issue = error as? SteamCMDSetupIssue, issue.kind == .securityApprovalRequired {
                try check(token)
                record.detail = issue.detail
                try persistPending(record)
                retain = true
            }
            throw error
        }
    }

    private func finishInstallation(_ record: PendingInstallation, staging: URL, container: URL, runtimeRoot: URL,
                                    environment: [String: String], diagnostics: SteamCMDOutputBuffer, token: UUID) async throws {
        let fm = FileManager.default
        try await runtimeProvider.validate(at: runtimeRoot)
        try check(token)
        let runtime = try runtimeProvider.resolve(executable: runtimeRoot.appendingPathComponent("steamcmd"))
        // Exercise the same validated private-copy path used by downloads. macOS can kill a
        // quarantined CLI at exec even when spctl reports valid non-app code. prepare validates
        // the source, clears quarantine only on its disposable copy, then validates that copy;
        // it never bypasses a policy denial or changes the candidate's download marks.
        let smokeRoot = staging.appendingPathComponent("smoke-runtime", isDirectory: true)
        defer { try? fm.removeItem(at: smokeRoot) }
        let smokeExecutable = try await runtimeProvider.prepare(executable: runtime.executableURL, staging: smokeRoot)
        try check(token)
        var smokeEnvironment = environment
        smokeEnvironment["DYLD_LIBRARY_PATH"] = smokeRoot.path
        smokeEnvironment["DYLD_FRAMEWORK_PATH"] = smokeRoot.appendingPathComponent("Frameworks").path
        let smoke = try await processRunner.run(executable: smokeExecutable,
            arguments: ["-inhibitbootstrap", "+quit"], workingDirectory: smokeRoot,
            environment: smokeEnvironment, onOutput: { diagnostics.append($0) })
        guard smoke == 0 else {
            throw SteamCMDSetupIssue(kind: .updateFailed, detail: String(localized: "SteamCMD's no-login verification exited with status \(smoke). \(diagnostics.text)"))
        }
        try check(token)
        try await runtimeProvider.validate(at: runtimeRoot)
        // No suspension from the cancellation check through the publication/selection update.
        try check(token)
        state = .committing
        try Self.requireSafeDirectory(managedURL, mayBeMissing: true)
        if fm.fileExists(atPath: managedURL.path) {
            guard record.replacingExisting else {
                throw SteamCMDSetupIssue(kind: .fileSystem, detail: String(localized: "Another SteamCMD installation appeared. Confirm replacement and retry."))
            }
            let backupName = ".steamcmd-backup-\(UUID().uuidString)"
            let backup = supportDirectory.appendingPathComponent(backupName, isDirectory: true)
            do {
                _ = try fm.replaceItemAt(managedURL, withItemAt: container, backupItemName: backupName, options: .withoutDeletingBackupItem)
            } catch {
                if fm.fileExists(atPath: backup.path) {
                    do {
                        if fm.fileExists(atPath: managedURL.path) {
                            // Preserve the uncertain replacement inside our staging before restoring the old directory.
                            try fm.moveItem(at: managedURL, to: staging.appendingPathComponent("failed-publication"))
                        }
                        try fm.moveItem(at: backup, to: managedURL)
                    } catch {
                        throw SteamCMDSetupIssue(kind: .fileSystem, detail: String(localized: "SteamCMD replacement and recovery failed. The previous installation backup is at \(backup.path). \(error.localizedDescription)"))
                    }
                }
                throw SteamCMDSetupIssue(kind: .fileSystem, detail: String(localized: "SteamCMD could not be replaced. \(error.localizedDescription)"))
            }
            try? fm.removeItem(at: backup)
        } else {
            try fm.moveItem(at: container, to: managedURL)
        }
        let installedRoot = managedURL.appendingPathComponent("MacOS", isDirectory: true)
        let installed = SteamCMDRuntime(rootURL: installedRoot, executableURL: installedRoot.appendingPathComponent("steamcmd"))
        defaults.set(installed.executableURL.path, forKey: Self.preferenceKey)
        selectedRuntime = installed
        state = .ready
    }

    private static func requireSafeDirectory(_ url: URL, mayBeMissing: Bool) throws {
        // Do not use standardizedFileURL here: Foundation can rewrite /private/var
        // to the /var symlink after the trusted system alias was normalized in init.
        var current = url.path
        guard url.isFileURL, current.hasPrefix("/"),
              !current.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw SteamCMDSetupIssue(kind: .fileSystem, detail: String(localized: "Unsafe installation directory: \(current)"))
        }
        while current != "/" {
            var info = stat()
            if lstat(current, &info) == 0 {
                guard info.st_mode & S_IFMT == S_IFDIR else {
                    throw SteamCMDSetupIssue(kind: .fileSystem, detail: String(localized: "Unsafe installation directory: \(current)"))
                }
            } else if errno != ENOENT || !mayBeMissing {
                throw SteamCMDSetupIssue(kind: .fileSystem, detail: String(localized: "Cannot access installation directory: \(current)"))
            }
            current = (current as NSString).deletingLastPathComponent
        }
    }

    /// `entries` maps every path already listed across this installation's packages to whether it
    /// is a directory: packages share directories but never a file, and `tar -k` would otherwise
    /// silently keep whichever copy came first.
    private static func validateListing(_ data: Data, entries: inout [String: Bool]) throws {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            throw SteamCMDSetupIssue(kind: .invalidArchive, detail: String(localized: "The SteamCMD archive listing is empty or unreadable."))
        }
        let unsafe = SteamCMDSetupIssue(kind: .invalidArchive, detail: String(localized: "The SteamCMD archive contains an unsafe path."))
        for entry in text.split(separator: "\n", omittingEmptySubsequences: true) {
            try Task.checkCancellation()
            guard let path = extractedPath(String(entry)), !path.hasPrefix("/"),
                  !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw unsafe }
            let components = path.split(separator: "/").filter { $0 != "." }
            guard !components.contains("..") else { throw unsafe }
            // A `./` entry names the extraction root itself.
            if components.isEmpty { guard path.hasSuffix("/") else { throw unsafe }; continue }
            let key = components.joined(separator: "/")
            let directory = path.hasSuffix("/")
            if let existing = entries[key], !(existing && directory) {
                throw SteamCMDSetupIssue(kind: .invalidArchive, detail: String(localized: "SteamCMD packages contain the same file more than once."))
            }
            entries[key] = directory
        }
    }

    /// bsdtar lists a literal backslash as `\\` and escapes every other unprintable byte. Extraction
    /// turns each backslash into `/` (Valve's zips use both separators), so the listing is decoded
    /// the same way; any other escape is refused rather than interpreted.
    private static func extractedPath(_ listed: String) -> String? {
        var path = ""
        var characters = listed.makeIterator()
        while let character = characters.next() {
            if character == "\\" {
                guard characters.next() == "\\" else { return nil }
                path.append("/")
            } else {
                path.append(character)
            }
        }
        return path
    }

    /// `total` accumulates across every package of one installation.
    private static func validateExpandedSizeListing(_ data: Data, total: inout Int64) throws {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            throw SteamCMDSetupIssue(kind: .invalidArchive, detail: String(localized: "The SteamCMD archive's size listing is unreadable."))
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            try Task.checkCancellation()
            // macOS bsdtar under LC_ALL=C and --numeric-owner prints:
            // permissions links uid gid size month day time-or-year pathname.
            // Reject unknown output instead of interpreting warnings or another format as zero bytes.
            let fields = line.split(maxSplits: 8, whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count == 9, let kind = fields[0].first, "-dl".contains(kind),
                  UInt64(fields[1]) != nil, UInt64(fields[2]) != nil, UInt64(fields[3]) != nil,
                  !fields[4].isEmpty, fields[4].utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                  let size = Int64(fields[4]), size >= 0 else {
                throw SteamCMDSetupIssue(kind: .invalidArchive, detail: String(localized: "The SteamCMD archive contains an unparseable size or unsupported entry."))
            }
            if kind == "-" {
                let (sum, overflow) = total.addingReportingOverflow(size)
                guard !overflow, sum <= 256 * 1024 * 1024 else {
                    throw SteamCMDSetupIssue(kind: .invalidArchive, detail: String(localized: "The expanded SteamCMD archive exceeds 256 MiB."))
                }
                total = sum
            }
        }
    }

    private static func inspectAndQuarantine(_ root: URL, byteLimit: Int64?) async throws {
        let inspection = Task.detached(priority: .utility) {
            try inspectAndQuarantineFiles(root, byteLimit: byteLimit)
        }
        try await withTaskCancellationHandler {
            try await inspection.value
            try Task.checkCancellation()
        } onCancel: {
            inspection.cancel()
        }
    }

    private nonisolated static func inspectAndQuarantineFiles(_ root: URL, byteLimit: Int64?) throws {
        let fm = FileManager.default
        var total: Int64 = 0
        let canonicalRoot = resolvedPath(root) + "/"
        let quarantine = "0083;\(String(Int(Date().timeIntervalSince1970), radix: 16));WallpaperMachine;\(UUID().uuidString)"
        func walk(_ directory: URL) throws {
            for file in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                try Task.checkCancellation()
                var info = stat()
                guard lstat(file.path, &info) == 0 else {
                    throw SteamCMDSetupIssue(kind: .invalidArchive, detail: String(localized: "Cannot inspect extracted SteamCMD file."))
                }
                switch info.st_mode & S_IFMT {
                case S_IFDIR:
                    guard chmod(file.path, 0o755) == 0 else { throw issue(NSError(domain: NSPOSIXErrorDomain, code: Int(errno))) }
                    try walk(file)
                case S_IFREG:
                    guard info.st_nlink == 1 else {
                        throw SteamCMDSetupIssue(kind: .invalidArchive, detail: String(localized: "Hard-linked SteamCMD files are not allowed."))
                    }
                    let (sum, overflow) = total.addingReportingOverflow(Int64(info.st_size))
                    guard !overflow, byteLimit.map({ sum <= $0 }) ?? true else {
                        throw SteamCMDSetupIssue(kind: .invalidArchive, detail: String(localized: "The expanded SteamCMD archive exceeds 256 MiB."))
                    }
                    total = sum
                    // Valve's zips record no permission bits (its updater sets them itself), so code
                    // images become executable here; nothing gains set-ID or group/other write.
                    let executable = info.st_mode & 0o111 != 0 || isMachO(file)
                    guard chmod(file.path, executable ? 0o755 : 0o644) == 0 else { throw issue(NSError(domain: NSPOSIXErrorDomain, code: Int(errno))) }
                    let marked = quarantine.withCString { setxattr(file.path, "com.apple.quarantine", $0, strlen($0), 0, XATTR_NOFOLLOW) }
                    guard marked == 0 else {
                        throw SteamCMDSetupIssue(kind: .fileSystem, detail: String(localized: "Cannot preserve downloaded-file security metadata: \(file.lastPathComponent)."))
                    }
                case S_IFLNK:
                    let target = try fm.destinationOfSymbolicLink(atPath: file.path)
                    // Breakpad.framework's version links: accept any relative link that resolves inside
                    // this tree; reject absolute, dangling, or escaping ones.
                    let resolved = resolvedPath(file)
                    guard !target.hasPrefix("/"), !target.isEmpty,
                          !target.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                          resolved.hasPrefix(canonicalRoot), fm.fileExists(atPath: resolved) else {
                        throw SteamCMDSetupIssue(kind: .invalidArchive, detail: String(localized: "The SteamCMD archive contains an external or unresolved symbolic link."))
                    }
                    // Foundation can leave a cyclic path unresolved; require a real final non-link object.
                    var targetInfo = stat()
                    guard lstat(resolved, &targetInfo) == 0, targetInfo.st_mode & S_IFMT != S_IFLNK else {
                        throw SteamCMDSetupIssue(kind: .invalidArchive, detail: String(localized: "The SteamCMD archive contains a cyclic symbolic link."))
                    }
                default:
                    throw SteamCMDSetupIssue(kind: .invalidArchive, detail: String(localized: "Special files are not allowed in SteamCMD archives."))
                }
            }
        }
        try walk(root)
    }

    private nonisolated static func isMachO(_ url: URL) -> Bool {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var magic = [UInt8](repeating: 0, count: 4)
        guard Darwin.read(descriptor, &magic, 4) == 4 else { return false }
        let value = magic.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return [0xfeedface, 0xcefaedfe, 0xfeedfacf, 0xcffaedfe, 0xcafebabe, 0xbebafeca, 0xcafebabf, 0xbfbafeca].contains(value)
    }

    /// POSIX realpath keeps /var and /tmp identities stable when checking link containment.
    private nonisolated static func resolvedPath(_ url: URL) -> String {
        if let resolved = realpath(url.path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        return url.resolvingSymlinksInPath().path
    }

    private nonisolated static func issue(_ error: Error) -> SteamCMDSetupIssue {
        (error as? SteamCMDSetupIssue) ?? SteamCMDSetupIssue(kind: .fileSystem, detail: error.localizedDescription)
    }
}

private final class SteamCMDOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var storage = Data()
    private var exceeded = false
    init(limit: Int) { self.limit = limit }
    func append(_ data: Data) {
        lock.withLock {
            if storage.count + data.count > limit { exceeded = true }
            storage.append(data)
            if storage.count > limit { storage.removeFirst(storage.count - limit) }
        }
    }
    var data: Data { lock.withLock { storage } }
    var text: String { String(decoding: data, as: UTF8.self) }
    var overflowed: Bool { lock.withLock { exceeded } }
}
