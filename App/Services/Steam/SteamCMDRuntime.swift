import CryptoKit
import Darwin
import Foundation

struct SteamCMDRuntime: Equatable, Sendable {
    /// Directory directly containing steamcmd, either a legacy flat root or MacOS.
    let rootURL: URL
    let executableURL: URL
}

protocol SteamCMDRuntimeProviding: Sendable {
    func resolve(executable: URL) throws -> SteamCMDRuntime
    func prepare(executable: URL, staging: URL) async throws -> URL
    func validate(at root: URL) async throws
}

struct SteamCMDApprovalCandidate: Equatable, Sendable {
    let rootURL: URL
    let fingerprint: String
}

protocol SteamCMDRuntimeApproving: Sendable {
    func approvalCandidate(at root: URL) async throws -> SteamCMDApprovalCandidate
    func approve(_ candidate: SteamCMDApprovalCandidate) async throws
}

/// SteamCMD runs only as Apple silicon code: Rosetta is not part of macOS 28's general app
/// support, so every launch and every validated image must carry an arm64 slice.
enum SteamCMDArchitecture {
    static let arm64: UInt32 = 0x0100_000c
    static let x86_64: UInt32 = 0x0100_0007

    /// Selects only native slices (x86_64 or arm64); an image without one fails with EBADARCH instead of being
    /// translated. Subtype ANY keeps system tools such as tar and codesign launchable.
    static func requireNative(_ attributes: inout posix_spawnattr_t?) -> Int32 {
#if arch(x86_64)
        var types = [cpu_type_t(bitPattern: x86_64)]
#else
        var types = [cpu_type_t(bitPattern: arm64)]
#endif
        var subtypes = [cpu_subtype_t(-1)]  // CPU_SUBTYPE_ANY
        var count = 0
        return posix_spawnattr_setarchpref_np(&attributes, 1, &types, &subtypes, &count)
    }
}

/// External runtimes are read-only except for an explicit, content-bound approval.
struct SteamCMDRuntimeService: SteamCMDRuntimeProviding, SteamCMDRuntimeApproving {
    private let processRunner: any SteamCMDProcessRunning
    private let approvalDirectory: URL
    private static let runtimeNames = [
        "steamcmd", "steamcmd.sh", "Frameworks", "crashhandler.dylib", "Steam.AppBundle",
        "steamconsole.dylib", "steamclient.dylib", "libtier0_s.dylib", "libvstdlib_s.dylib",
        "libaudio.dylib", "libsteaminput.dylib", "public", "package"
    ]
    /// Valve's Developer ID team. Only the spawned executable can be pinned to it: Valve ships
    /// libsteaminput.dylib ad-hoc signed, so the runtime has no single signing authority.
    private static let valveAuthority = #"anchor apple generic and certificate leaf[subject.OU] = "MXGJJ98X76""#

    init(processRunner: any SteamCMDProcessRunning = SteamCMDProcessRunner(),
         approvalDirectory: URL = ClientPaths.supportURL.appendingPathComponent("SteamCMDApprovals", isDirectory: true)) {
        self.processRunner = processRunner
        self.approvalDirectory = approvalDirectory
    }

    func approvalCandidate(at root: URL) async throws -> SteamCMDApprovalCandidate {
        guard root.isFileURL else { throw approvalFailure() }
        // Reject a selected root symlink before canonicalizing Apple's /var alias.
        var metadata = stat()
        guard lstat(root.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR else { throw approvalFailure() }
        let canonical = canonicalURL(root)
        let before = try fingerprint(at: canonical)
        try await validate(root: canonical, preparingApproval: true)
        guard try fingerprint(at: canonical) == before else { throw approvalFailure() }
        return SteamCMDApprovalCandidate(rootURL: canonical, fingerprint: before)
    }

    func approve(_ candidate: SteamCMDApprovalCandidate) async throws {
        let current = try await approvalCandidate(at: candidate.rootURL)
        guard current == candidate else { throw approvalFailure() }
        let receipts = canonicalURL(approvalDirectory)
        guard receipts != candidate.rootURL, !contained(receipts, in: candidate.rootURL) else { throw approvalFailure() }
        // Open the private receipt destination before changing anything in the runtime.
        let directory = try openApprovalDirectory(create: true)
        defer { close(directory) }
        _ = try readApproval(candidate.fingerprint, directory: directory)
        _ = try fingerprint(at: candidate.rootURL, removingQuarantine: true)
        let after = try await approvalCandidate(at: candidate.rootURL)
        guard after == candidate else { throw approvalFailure() }
        try saveApproval(candidate.fingerprint, directory: directory)
    }

    private func approvalFailure() -> SteamCMDSetupIssue {
        issue(.fileSystem, "The SteamCMD approval candidate or private approval record changed or is unsafe. Review the current copy again; no approval was saved.")
    }

    /// Hash only the same allowlisted trees that validation and private copying consume.
    /// File descriptors prevent traversal through swapped links; bytes are read in bounded chunks.
    private func fingerprint(at root: URL, removingQuarantine: Bool = false) throws -> String {
        var directory = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw approvalFailure() }
        defer { close(directory) }
        for component in root.pathComponents.dropFirst() {
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw approvalFailure() }
            close(directory)
            directory = next
        }
        var hash = SHA256()
        var entries = 0
        var totalBytes: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: 65536)
        func field(_ value: String) {
            var size = UInt64(value.utf8.count).bigEndian
            withUnsafeBytes(of: &size) { hash.update(bufferPointer: $0) }
            hash.update(data: Data(value.utf8))
        }
        func clear(_ descriptor: Int32) throws {
            guard !removingQuarantine || fremovexattr(descriptor, "com.apple.quarantine", 0) == 0 || errno == ENOATTR else {
                throw approvalFailure()
            }
        }
        func visit(_ name: String, parent: Int32, relative: String, depth: Int) throws {
            try Task.checkCancellation()
            entries += 1
            guard entries <= 100_000, depth <= 64 else { throw approvalFailure() }
            var metadata = stat()
            guard fstatat(parent, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0,
                  metadata.st_mode & 0o6000 == 0 else { throw approvalFailure() }
            field(relative)
            field(String(metadata.st_mode))
            let type = metadata.st_mode & S_IFMT
            if type == S_IFLNK {
                var link = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
                let count = link.withUnsafeMutableBufferPointer { buffer in
                    readlinkat(parent, name, buffer.baseAddress, buffer.count)
                }
                guard count > 0, count < link.count else { throw approvalFailure() }
                link[count] = 0
                guard let target = String(validatingCString: link) else { throw approvalFailure() }
                field(target)
                // Framework links carry no executable bytes. Never mutate or follow them;
                // their contained regular-file targets are independently hashed and cleared.
                return
            }
            guard type == S_IFDIR || type == S_IFREG else { throw approvalFailure() }
            let descriptor = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (type == S_IFDIR ? O_DIRECTORY : 0))
            guard descriptor >= 0 else { throw approvalFailure() }
            defer { close(descriptor) }
            var opened = stat()
            guard fstat(descriptor, &opened) == 0, opened.st_dev == metadata.st_dev,
                  opened.st_ino == metadata.st_ino, opened.st_mode == metadata.st_mode else { throw approvalFailure() }
            if type == S_IFDIR {
                let copy = dup(descriptor)
                guard copy >= 0 else { throw approvalFailure() }
                guard let stream = fdopendir(copy) else { close(copy); throw approvalFailure() }
                defer { closedir(stream) }
                var names: [String] = []
                while true {
                    errno = 0
                    guard let entry = readdir(stream) else {
                        guard errno == 0 else { throw approvalFailure() }
                        break
                    }
                    let capacity = Int(entry.pointee.d_namlen) + 1
                    let child = withUnsafePointer(to: &entry.pointee.d_name) {
                        $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
                    }
                    if child != ".", child != ".." { names.append(child) }
                    guard names.count <= 100_000 else { throw approvalFailure() }
                }
                names.sort()
                for child in names { try visit(child, parent: descriptor, relative: relative + "/" + child, depth: depth + 1) }
            } else {
                guard opened.st_nlink == 1, opened.st_size >= 0 else { throw approvalFailure() }
                field(String(opened.st_size))
                var bytes: Int64 = 0
                while true {
                    try Task.checkCancellation()
                    let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
                    if count < 0, errno == EINTR { continue }
                    guard count >= 0 else { throw approvalFailure() }
                    if count == 0 { break }
                    bytes += Int64(count)
                    totalBytes += UInt64(count)
                    guard bytes <= opened.st_size, totalBytes <= 16 * 1024 * 1024 * 1024 else { throw approvalFailure() }
                    buffer.withUnsafeBytes { hash.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[..<count])) }
                }
                var finished = stat()
                guard bytes == opened.st_size, fstat(descriptor, &finished) == 0,
                      finished.st_size == opened.st_size, finished.st_mode == opened.st_mode,
                      finished.st_nlink == 1, finished.st_mtimespec.tv_sec == opened.st_mtimespec.tv_sec,
                      finished.st_mtimespec.tv_nsec == opened.st_mtimespec.tv_nsec,
                      finished.st_ctimespec.tv_sec == opened.st_ctimespec.tv_sec,
                      finished.st_ctimespec.tv_nsec == opened.st_ctimespec.tv_nsec else { throw approvalFailure() }
            }
            try clear(descriptor)
        }
        field("SteamCMD approval content v1")
        for name in Self.runtimeNames.sorted() {
            var metadata = stat()
            if fstatat(directory, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 {
                try visit(name, parent: directory, relative: name, depth: 0)
            } else if errno != ENOENT { throw approvalFailure() }
        }
        try clear(directory)
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// No validation call creates directories or records. Reject links at every storage component.
    private func openApprovalDirectory(create: Bool) throws -> Int32 {
        guard approvalDirectory.isFileURL else { throw approvalFailure() }
        var path = approvalDirectory.standardizedFileURL.path
        for alias in ["/var", "/tmp"] where path == alias || path.hasPrefix(alias + "/") {
            path = "/private" + path
        }
        let components = URL(fileURLWithPath: path).pathComponents.dropFirst()
        guard !components.isEmpty else { throw approvalFailure() }
        var directory = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw approvalFailure() }
        do {
            for component in components {
                var next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0, errno == ENOENT {
                    if !create { close(directory); return -1 }
                    guard mkdirat(directory, component, 0o700) == 0 || errno == EEXIST else { throw approvalFailure() }
                    next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else { throw approvalFailure() }
                close(directory)
                directory = next
            }
            var metadata = stat()
            guard fstat(directory, &metadata) == 0, metadata.st_uid == getuid(),
                  metadata.st_mode & 0o7777 == 0o700 else { throw approvalFailure() }
            return directory
        } catch {
            close(directory)
            throw error
        }
    }

    private func hasApproval(for fingerprint: String) throws -> Bool {
        let directory = try openApprovalDirectory(create: false)
        guard directory >= 0 else { return false }
        defer { close(directory) }
        return try readApproval(fingerprint, directory: directory)
    }

    private func readApproval(_ fingerprint: String, directory: Int32) throws -> Bool {
        let file = openat(directory, fingerprint, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if file < 0, errno == ENOENT { return false }
        guard file >= 0 else { throw approvalFailure() }
        defer { close(file) }
        let expected = Array(("SteamCMD approval v1\n" + fingerprint + "\n").utf8)
        var metadata = stat()
        guard fstat(file, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == getuid(), metadata.st_nlink == 1,
              metadata.st_mode & 0o7777 == 0o600, metadata.st_size == expected.count else { throw approvalFailure() }
        var contents = [UInt8](repeating: 0, count: expected.count)
        let readCount = contents.withUnsafeMutableBytes { Darwin.read(file, $0.baseAddress, $0.count) }
        guard readCount == expected.count, contents == expected else { throw approvalFailure() }
        return true
    }

    private func saveApproval(_ fingerprint: String, directory: Int32) throws {
        if try readApproval(fingerprint, directory: directory) { return }
        let temporary = ".approval-" + UUID().uuidString
        let file = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw approvalFailure() }
        defer { close(file); unlinkat(directory, temporary, 0) }
        let contents = Array(("SteamCMD approval v1\n" + fingerprint + "\n").utf8)
        let written = contents.withUnsafeBytes { Darwin.write(file, $0.baseAddress, $0.count) }
        guard written == contents.count, fsync(file) == 0,
              renameat(directory, temporary, directory, fingerprint) == 0 else { throw approvalFailure() }
    }

    func resolve(executable: URL) throws -> SteamCMDRuntime {
        try Task.checkCancellation()
        guard executable.isFileURL else { throw issue(.invalidSelection, "Choose a local macOS SteamCMD installation.") }
        var selected = canonicalURL(executable)
        // Only unwrap the exact Homebrew-generated command, never evaluate shell text.
        if let wrapper = try homebrewTarget(at: selected) { selected = canonicalURL(wrapper) }
        var directory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: selected.path, isDirectory: &directory) else {
            throw issue(.invalidSelection, "SteamCMD was not found at \(executable.path). Locate an existing installation or install SteamCMD.")
        }
        let root: URL
        if directory.boolValue {
            let macOS = selected.appendingPathComponent("MacOS", isDirectory: true)
            root = canonicalURL(FileManager.default.fileExists(atPath: macOS.appendingPathComponent("steamcmd").path) ? macOS : selected)
        } else {
            guard ["steamcmd", "steamcmd.sh"].contains(selected.lastPathComponent) else {
                throw issue(.invalidSelection, "Choose steamcmd, steamcmd.sh, or its flat/MacOS installation folder.")
            }
            root = canonicalURL(selected.deletingLastPathComponent())
        }
        let binary = root.appendingPathComponent("steamcmd")
        _ = try regularFile(binary)
        let images = try MachO.read(binary)
        guard !images.isEmpty, images.allSatisfy({ $0.fileType == 2 }),
              images.contains(where: { $0.cpu == SteamCMDArchitecture.x86_64 || $0.cpu == SteamCMDArchitecture.arm64 }),
              FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw issue(.invalidSelection, "\(binary.path) is not a macOS Mach-O SteamCMD executable.")
        }
        guard images.contains(where: {
#if arch(x86_64)
            $0.cpu == SteamCMDArchitecture.x86_64
#else
            $0.cpu == SteamCMDArchitecture.arm64
#endif
        }) else {
            throw appleSiliconIssue(binary)
        }
        return SteamCMDRuntime(rootURL: root, executableURL: binary)
    }

    func validate(at root: URL) async throws {
        try await validate(root: root, preparingApproval: false)
    }

    func prepare(executable: URL, staging: URL) async throws -> URL {
        let runtime = try resolve(executable: executable)
        try await validate(at: runtime.rootURL)
        try Task.checkCancellation()
        let files = FileManager.default
        var metadata = stat()
        var parent = stat()
        guard lstat(staging.path, &metadata) != 0, errno == ENOENT,
              lstat(staging.deletingLastPathComponent().path, &parent) == 0, parent.st_mode & S_IFMT == S_IFDIR else {
            throw issue(.fileSystem, "The private SteamCMD staging path is not safe: \(staging.path)")
        }
        try files.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        for name in Self.runtimeNames {
            try Task.checkCancellation()
            let source = runtime.rootURL.appendingPathComponent(name)
            if files.fileExists(atPath: source.path) {
                try files.copyItem(at: source, to: staging.appendingPathComponent(name))
            }
        }
        // macOS refuses to load a quarantined library into a process, so Valve's dlopen'd
        // components (steamclient.dylib and its siblings) fail with "library load disallowed
        // by system policy" at download time. Drop the download mark from this private copy
        // only; the selected installation is never touched, and the copy is revalidated below.
        _ = try fingerprint(at: canonicalURL(staging), removingQuarantine: true)
        // Revalidate the actual private copy, not just the source descriptor.
        try await validate(at: staging)
        return staging.appendingPathComponent("steamcmd")
    }

    private func homebrewTarget(at url: URL) throws -> URL? {
        let pattern = #"\A/(?:opt/homebrew|usr/local)/Caskroom/steamcmd/[^/]+/\.homebrew-command-wrappers/steamcmd\z"#
        let direct = ["/opt/homebrew/bin/steamcmd", "/usr/local/bin/steamcmd"].contains(url.path)
        guard direct || url.path.range(of: pattern, options: .regularExpression) != nil else { return nil }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber, size.intValue <= 4096,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let expression = try NSRegularExpression(pattern: #"\A#!/bin/bash\nexec \"((?:/opt/homebrew|/usr/local)/Caskroom/steamcmd/[A-Za-z0-9._-]+/MacOS/steamcmd\.sh)\" {1,2}\"\$@\"\n\z"#)
        guard let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else {
            throw issue(.invalidSelection, "The Homebrew SteamCMD wrapper has an unrecognized format. Locate the complete MacOS runtime directly.")
        }
        return URL(fileURLWithPath: String(text[range]))
    }

    private func validate(root: URL, preparingApproval: Bool) async throws {
        try Task.checkCancellation()
        let canonical = canonicalURL(root)
        var rootStat = stat()
        guard lstat(root.path, &rootStat) == 0, rootStat.st_mode & S_IFMT == S_IFDIR else {
            throw issue(.incompleteRuntime, "SteamCMD runtime directories cannot be symbolic links: \(root.path)")
        }
        let descriptor = try resolve(executable: canonical.appendingPathComponent("steamcmd"))
        guard descriptor.rootURL == canonical else { throw issue(.incompleteRuntime, "Unexpected SteamCMD runtime layout.") }
        _ = try regularFile(canonical.appendingPathComponent("crashhandler.dylib"))
        do { _ = try regularFile(canonical.appendingPathComponent("steamconsole.dylib")) }
        catch { throw issue(.incompleteRuntime, "SteamCMD at \(root.path) needs to finish installation: steamconsole.dylib is missing, empty, or unreadable.") }
        let framework = canonical.appendingPathComponent("Frameworks/Breakpad.framework", isDirectory: true)
        var frameworkStat = stat()
        guard lstat(framework.path, &frameworkStat) == 0, frameworkStat.st_mode & S_IFMT == S_IFDIR else {
            throw issue(.incompleteRuntime, "SteamCMD is missing its Breakpad.framework directory.")
        }
        var binaries: [URL: [MachO.Image]] = [:]
        for name in Self.runtimeNames {
            let url = canonical.appendingPathComponent(name)
            var metadata = stat()
            if lstat(url.path, &metadata) == 0 { try inspect(url, root: canonical, binaries: &binaries) }
            else if errno != ENOENT { throw issue(.incompleteRuntime, "Cannot inspect \(url.path).") }
        }
        for name in ["steamcmd", "crashhandler.dylib", "steamconsole.dylib"] {
            guard binaries[canonicalURL(canonical.appendingPathComponent(name))] != nil else {
                throw issue(.incompleteRuntime, "\(name) is not a valid Mach-O runtime component.")
            }
        }
        // Any image without arm64 code could only ever run translated, so the whole copy is
        // treated as an Intel build that a native reinstall replaces.
        if let missingNative = binaries.keys.sorted(by: { $0.path < $1.path }).first(where: { binary in
#if arch(x86_64)
            !(binaries[binary] ?? []).contains { $0.cpu == SteamCMDArchitecture.x86_64 }
#else
            !(binaries[binary] ?? []).contains { $0.cpu == SteamCMDArchitecture.arm64 }
#endif
        }) {
            throw appleSiliconIssue(missingNative)
        }
        let frameworkBinary = canonicalURL(framework.appendingPathComponent("Breakpad"))
        guard let frameworkImages = binaries[frameworkBinary] else { throw issue(.incompleteRuntime, "Breakpad.framework has no valid Mach-O binary.") }
        try validateDependencies(binaries, runtime: descriptor)
        let verifiedFingerprint = try fingerprint(at: canonical)
        // Valve rules out both a bundle-wide and a whole-file verification: their packages contain a
        // Breakpad.framework whose sealed Headers/Breakpad.h no longer matches its own CodeResources,
        // and steamclient.dylib keeps unsigned bytes in its fat-header padding, which fails a universal
        // verify while every slice verifies. Check the code seal dyld actually enforces, once per slice,
        // across every Mach-O image found by walking the runtime; that reaches more than --deep, which
        // only follows sealed resources. No repair/sign operation exists here.
        let signed = [(framework, frameworkImages)] + binaries.sorted { $0.key.path < $1.key.path }.map { ($0.key, $0.value) }
        for (target, images) in signed {
            let requirement = target == descriptor.executableURL ? ["-R=" + Self.valveAuthority] : []
            for image in images {
                let architecture = try architectureName(for: image.cpu, at: target)
                let status = try await runSystem("/usr/bin/codesign",
                                                 ["--verify", "--strict", "--ignore-resources", "--arch", architecture] + requirement + [target.path],
                                                 root: canonical).status
                guard status == 0 else { throw issue(.invalidSignature, "SteamCMD signature validation failed for \(target.path). Select a valid installation or reinstall; no signatures were changed.") }
            }
        }
        let assessment = try await runSystem("/usr/sbin/spctl", ["--assess", "--type", "execute", "--verbose=2", descriptor.executableURL.path], root: canonical)
        // spctl(8): only exit 3 is policy denial; 1/2/4 are operational failures.
        guard assessment.status == 0 || assessment.status == 3 else {
            throw issue(.securityApprovalRequired, "macOS could not complete its SteamCMD security assessment. Retry after resolving the system security error; an explicit approval cannot bypass an assessment failure.")
        }
        if assessment.status != 0, !preparingApproval {
            // --type execute is for app bundles. Valve's steamcmd is a signed CLI tool, so
            // assessment exits 3 with this diagnostic even when codesign --strict succeeded.
            let commandLineTool = assessment.output.contains("the code is valid but does not seem to be an app")
            if !commandLineTool {
                guard try fingerprint(at: canonical) == verifiedFingerprint,
                      try hasApproval(for: verifiedFingerprint) else {
                    throw issue(.securityApprovalRequired, "macOS has not approved SteamCMD at \(descriptor.executableURL.path). Review and approve this SteamCMD copy, or follow Apple’s app security guidance, then Retry. System security settings have not been changed.")
                }
            }
        }
        try Task.checkCancellation()
    }

    private func appleSiliconIssue(_ image: URL) -> SteamCMDSetupIssue {
        issue(.appleSiliconRequired, "This SteamCMD copy is built for Intel Macs only (\(image.lastPathComponent)). Reinstall SteamCMD to get Valve’s Apple silicon version.")
    }

    private func validateDependencies(_ binaries: [URL: [MachO.Image]], runtime: SteamCMDRuntime) throws {
        struct Slice: Hashable {
            let binary: URL
            let cpu: UInt32
        }
        struct Context: Hashable {
            let slice: Slice
            let executable: URL
            let runPaths: [URL]
        }
        var validated: Set<Context> = []
        var reached: Set<Slice> = []

        func traverse(_ binary: URL, cpu: UInt32, executable: URL, inheritedRunPaths: [URL],
                      ancestors: inout Set<Slice>) throws {
            try Task.checkCancellation()
            let slice = Slice(binary: binary, cpu: cpu)
            guard let image = binaries[binary]?.first(where: { $0.cpu == cpu }) else {
                throw issue(.incompleteRuntime, "Missing architecture-compatible runtime image: \(binary.path)")
            }
            // A dependency cycle reuses the already-loading image, not a new dyld context.
            guard !ancestors.contains(slice) else { return }
            var runPaths = try image.rpaths.map { try expanded($0, loader: binary, executable: executable, root: runtime.rootURL) }
            for inherited in inheritedRunPaths where !runPaths.contains(inherited) { runPaths.append(inherited) }
            let context = Context(slice: slice, executable: executable, runPaths: runPaths)
            guard !validated.contains(context) else { return }
            ancestors.insert(slice)
            defer { ancestors.remove(slice) }
            for dependency in image.dependencies where !isSystem(dependency) {
                var candidates: [URL]
                if dependency.hasPrefix("@rpath/") {
                    let suffix = String(dependency.dropFirst(7))
                    candidates = runPaths.map { canonicalURL($0.appendingPathComponent(suffix)) }
                } else {
                    candidates = [try expanded(dependency, loader: binary, executable: executable, root: runtime.rootURL)]
                }
                // Valve's framework install names also use the controlled DYLD_FRAMEWORK_PATH.
                let components = dependency.split(separator: "/")
                if let index = components.firstIndex(where: { $0.hasSuffix(".framework") }) {
                    let relative = components[index...].joined(separator: "/")
                    candidates.insert(canonicalURL(runtime.rootURL.appendingPathComponent("Frameworks").appendingPathComponent(relative)), at: 0)
                }
                guard let target = candidates.first(where: { candidate in
                    contained(candidate, in: runtime.rootURL)
                        && binaries[candidate]?.contains(where: { $0.cpu == cpu && $0.fileType != 2 }) == true
                }) else {
                    throw issue(.incompleteRuntime, "\(binary.lastPathComponent) needs missing or external runtime dependency \(dependency). Complete the official SteamCMD installation.")
                }
                // @executable_path keeps the launching helper's identity throughout its dylib chain.
                try traverse(target, cpu: cpu, executable: executable, inheritedRunPaths: runPaths, ancestors: &ancestors)
            }
            reached.insert(slice)
            validated.insert(context)
        }

        let ordered = binaries.keys.sorted(by: { $0.path < $1.path })
        for binary in ordered {
            for image in binaries[binary] ?? [] where image.fileType == 2 {
                var ancestors: Set<Slice> = []
                try traverse(binary, cpu: image.cpu, executable: binary, inheritedRunPaths: [], ancestors: &ancestors)
            }
        }
        // Steam loads its root-level libraries dynamically; they are additional steamcmd roots,
        // even if a helper also references the same dylib in a different executable context.
        for binary in ordered {
            for image in binaries[binary] ?? [] where image.fileType != 2 {
                let isRootLibrary = binary.deletingLastPathComponent() == runtime.rootURL
                guard isRootLibrary || !reached.contains(Slice(binary: binary, cpu: image.cpu)) else { continue }
                let mainImage = binaries[runtime.executableURL]?.first(where: { $0.cpu == image.cpu })
                let inherited = try (mainImage?.rpaths ?? []).map {
                    try expanded($0, loader: runtime.executableURL, executable: runtime.executableURL, root: runtime.rootURL)
                }
                var ancestors: Set<Slice> = []
                try traverse(binary, cpu: image.cpu, executable: runtime.executableURL,
                             inheritedRunPaths: inherited, ancestors: &ancestors)
            }
        }
    }

    private func runSystem(_ path: String, _ arguments: [String], root: URL) async throws -> (status: Int32, output: String) {
        try Task.checkCancellation()
        return try await withThrowingTaskGroup(of: (Int32, String).self) { group in
            group.addTask {
                let collected = SystemCommandOutput()
                let status = try await processRunner.run(executable: URL(fileURLWithPath: path), arguments: arguments,
                                                         workingDirectory: root,
                                                         environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"],
                                                         onOutput: { collected.append($0) })
                return (status, collected.text)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(30))
                throw issue(.timedOut, "SteamCMD system validation timed out while running \(path). Retry after checking system security prompts.")
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            return (result.0, result.1)
        }
    }

    private func inspect(_ url: URL, root: URL, binaries: inout [URL: [MachO.Image]]) throws {
        try Task.checkCancellation()
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0, metadata.st_mode & 0o6000 == 0 else {
            throw issue(.incompleteRuntime, "Unreadable or unsafe runtime entry: \(url.path)")
        }
        switch metadata.st_mode & S_IFMT {
        case S_IFDIR:
            for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                try inspect(child, root: root, binaries: &binaries)
            }
        case S_IFREG:
            guard metadata.st_nlink == 1, FileManager.default.isReadableFile(atPath: url.path) else {
                throw issue(.incompleteRuntime, "Unreadable or hard-linked runtime file: \(url.path)")
            }
            let images = try MachO.read(url)
            if !images.isEmpty { binaries[canonicalURL(url)] = images }
        case S_IFLNK:
            let frameworkComponents = url.pathComponents.dropLast()
            guard let index = frameworkComponents.firstIndex(where: { $0.hasSuffix(".framework") }) else {
                throw issue(.incompleteRuntime, "Only contained framework symbolic links are accepted: \(url.path)")
            }
            let frameworkRoot = canonicalURL(URL(fileURLWithPath: NSString.path(withComponents: Array(url.pathComponents[...index])), isDirectory: true))
            let target = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
            let resolved = canonicalURL(url)
            guard !target.hasPrefix("/"), !target.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  contained(resolved, in: frameworkRoot), contained(resolved, in: root),
                  FileManager.default.fileExists(atPath: resolved.path), resolved.path != url.path else {
                throw issue(.incompleteRuntime, "Broken, cyclic, or escaping framework symbolic link: \(url.path)")
            }
        default:
            throw issue(.incompleteRuntime, "Special files are not accepted in SteamCMD: \(url.path)")
        }
    }

    private func regularFile(_ url: URL) throws -> stat {
        var value = stat()
        guard lstat(url.path, &value) == 0, value.st_mode & S_IFMT == S_IFREG, value.st_nlink == 1,
              value.st_size > 0, value.st_mode & 0o6000 == 0, FileManager.default.isReadableFile(atPath: url.path) else {
            throw issue(.incompleteRuntime, "Missing, empty, unreadable, or unsafe SteamCMD file: \(url.path)")
        }
        return value
    }

    /// codesign needs an explicit slice: Valve's steamclient.dylib carries unsigned bytes in its
    /// fat-header padding, which makes a whole-file verification fail while each slice verifies.
    private func architectureName(for cpu: UInt32, at url: URL) throws -> String {
        switch cpu {
        case 0x0100_000c: return "arm64"
        case 0x0100_0007: return "x86_64"
        case 0x0000_0007: return "i386"
        default: throw issue(.incompleteRuntime, "Unsupported SteamCMD runtime architecture in \(url.path).")
        }
    }

    private func expanded(_ path: String, loader: URL, executable: URL, root: URL) throws -> URL {
        let url: URL
        if path == "@loader_path" || path.hasPrefix("@loader_path/") {
            url = loader.deletingLastPathComponent().appendingPathComponent(String(path.dropFirst("@loader_path".count).drop(while: { $0 == "/" })))
        } else if path == "@executable_path" || path.hasPrefix("@executable_path/") {
            url = executable.deletingLastPathComponent().appendingPathComponent(String(path.dropFirst("@executable_path".count).drop(while: { $0 == "/" })))
        } else if path.hasPrefix("/") {
            url = URL(fileURLWithPath: path)
        } else {
            throw issue(.incompleteRuntime, "Unresolved SteamCMD dynamic loader path: \(path)")
        }
        let resolved = canonicalURL(url)
        guard contained(resolved, in: root) || resolved == root else {
            throw issue(.incompleteRuntime, "SteamCMD dynamic loader path escapes its runtime: \(path)")
        }
        return resolved
    }

    private func isSystem(_ path: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        let canonical = URL(fileURLWithPath: path).standardizedFileURL.path
        return canonical.hasPrefix("/usr/lib/") || canonical.hasPrefix("/System/Library/")
    }

    private func contained(_ url: URL, in root: URL) -> Bool {
        let path = canonicalURL(url).pathComponents
        let parent = canonicalURL(root).pathComponents
        return path.count > parent.count && path.starts(with: parent)
    }

    /// Foundation can alternate /var and /private/var when resolving framework links.
    /// POSIX realpath supplies one identity for traversal, dependency keys, and containment.
    /// Missing loader candidates retain a canonical existing ancestor, so optional search paths
    /// can be checked without pretending an unresolved candidate is an installed dependency.
    private func canonicalURL(_ url: URL) -> URL {
        var ancestor = url
        var suffix: [String] = []
        while true {
            if let resolved = realpath(ancestor.path, nil) {
                defer { free(resolved) }
                var components = URL(fileURLWithPath: String(cString: resolved)).pathComponents
                for component in suffix.reversed() {
                    if component == "." { continue }
                    if component == ".." {
                        if components.count > 1 { components.removeLast() }
                    } else {
                        components.append(component)
                    }
                }
                return URL(fileURLWithPath: NSString.path(withComponents: components))
            }
            guard ancestor.path != "/", !ancestor.lastPathComponent.isEmpty else { return url }
            suffix.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
    }
    private func issue(_ kind: SteamCMDSetupIssue.Kind, _ detail: String.LocalizationValue) -> SteamCMDSetupIssue {
        SteamCMDSetupIssue(kind: kind, detail: String(localized: detail))
    }
}

private final class SystemCommandOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    func append(_ data: Data) {
        lock.withLock {
            let remaining = max(0, 16 * 1024 - storage.count)
            if remaining > 0 { storage.append(data.prefix(remaining)) }
        }
    }
    var text: String { lock.withLock { String(decoding: storage, as: UTF8.self) } }
}

/// Bounds-checked Mach-O load-command reader; no subprocess or executable probing.
private enum MachO {
    struct Image {
        let cpu: UInt32
        let fileType: UInt32
        let dependencies: [String]
        let rpaths: [String]
    }

    static func read(_ url: URL) throws -> [Image] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 4) ?? Data()
        guard prefix.count == 4 else { return [] }
        let magic = prefix.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard [0xfeedface, 0xcefaedfe, 0xfeedfacf, 0xcffaedfe, 0xcafebabe, 0xbebafeca, 0xcafebabf, 0xbfbafeca].contains(magic) else { return [] }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        func malformed() -> SteamCMDSetupIssue {
            SteamCMDSetupIssue(kind: .incompleteRuntime, detail: String(localized: "Malformed Mach-O runtime file: \(url.path)"))
        }
        func number(_ offset: Int, _ width: Int, _ little: Bool) throws -> UInt64 {
            guard offset >= 0, offset <= data.count, width <= data.count - offset else { throw malformed() }
            var value: UInt64 = 0
            for i in 0..<width {
                let index = little ? offset + width - 1 - i : offset + i
                value = (value << 8) | UInt64(data[index])
            }
            return value
        }
        func image(_ offset: Int, _ size: Int) throws -> Image {
            guard offset >= 0, size >= 28, offset <= data.count, size <= data.count - offset else { throw malformed() }
            let magic = try number(offset, 4, false)
            let little = magic == 0xcefaedfe || magic == 0xcffaedfe
            guard [0xfeedface, 0xcefaedfe, 0xfeedfacf, 0xcffaedfe].contains(magic) else { throw malformed() }
            let headerSize = magic == 0xfeedfacf || magic == 0xcffaedfe ? 32 : 28
            let cpu = UInt32(try number(offset + 4, 4, little))
            let type = UInt32(try number(offset + 12, 4, little))
            let count = Int(try number(offset + 16, 4, little))
            let commandBytes = Int(try number(offset + 20, 4, little))
            guard headerSize <= size, commandBytes <= size - headerSize, count <= commandBytes / 8 else { throw malformed() }
            var cursor = offset + headerSize
            let end = cursor + commandBytes
            var dependencies: [String] = []
            var rpaths: [String] = []
            for _ in 0..<count {
                try Task.checkCancellation()
                guard cursor <= end - 8 else { throw malformed() }
                let command = UInt32(try number(cursor, 4, little))
                let length = Int(try number(cursor + 4, 4, little))
                guard length >= 8, length <= end - cursor, length % 4 == 0 else { throw malformed() }
                let dylib = [UInt32(0xc), 0x80000018, 0x8000001f, 0x20, 0x80000023].contains(command)
                if dylib || command == 0x8000001c {
                    let minimum = dylib ? 24 : 12
                    guard length >= minimum else { throw malformed() }
                    let start = Int(try number(cursor + 8, 4, little))
                    guard start >= minimum, start < length,
                          let terminator = data[(cursor + start)..<(cursor + length)].firstIndex(of: 0),
                          let text = String(data: data[(cursor + start)..<terminator], encoding: .utf8), !text.isEmpty,
                          !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw malformed() }
                    if dylib { dependencies.append(text) } else { rpaths.append(text) }
                }
                cursor += length
            }
            guard cursor == end else { throw malformed() }
            return Image(cpu: cpu, fileType: type, dependencies: dependencies, rpaths: rpaths)
        }
        let fat = [UInt32(0xcafebabe), 0xbebafeca, 0xcafebabf, 0xbfbafeca].contains(magic)
        guard fat else { return [try image(0, data.count)] }
        let little = magic == 0xbebafeca || magic == 0xbfbafeca
        let wide = magic == 0xcafebabf || magic == 0xbfbafeca
        let count = Int(try number(4, 4, little))
        let row = wide ? 32 : 20
        guard count > 0, count <= (data.count - 8) / row else { throw malformed() }
        var images: [Image] = []
        var ranges: [Range<Int>] = []
        for index in 0..<count {
            try Task.checkCancellation()
            let cursor = 8 + index * row
            let cpu = UInt32(try number(cursor, 4, little))
            let offsetValue = try number(cursor + 8, wide ? 8 : 4, little)
            let sizeValue = try number(cursor + (wide ? 16 : 12), wide ? 8 : 4, little)
            guard offsetValue <= UInt64(Int.max), sizeValue <= UInt64(Int.max) else { throw malformed() }
            let offset = Int(offsetValue), size = Int(sizeValue)
            guard offset >= 8 + count * row, offset <= data.count, size <= data.count - offset else { throw malformed() }
            let range = offset..<(offset + size)
            // Dependency resolution and codesign's --arch both select a slice by CPU type alone,
            // so a repeated type would leave one slice unresolved and unverified.
            guard !ranges.contains(where: { $0.overlaps(range) }), !images.contains(where: { $0.cpu == cpu }) else { throw malformed() }
            ranges.append(range)
            let parsed = try image(offset, size)
            guard parsed.cpu == cpu else { throw malformed() }
            images.append(parsed)
        }
        return images
    }
}
