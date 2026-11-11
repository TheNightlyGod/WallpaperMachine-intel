import Foundation

/// A zip a user can attach to a bug report: recent logs, the lock-screen
/// extension log, the load journal, crash reports, macOS resource, spin and
/// hang reports, and the environment lines they were asked for.
///
/// Synchronous and off the main actor. The caller decides where it runs.
/// Missing sources are notes in the report, not failures — a bug report with
/// no crash reports is still worth sending.
struct DiagnosticsBundle {
    struct Sources {
        var logsRoot: URL
        var extensionLog: URL
        var crashReports: URL
        /// The bridge's `load-journal.json` (see docs/features/crash-recovery.md).
        /// `nil` means the caller has no journal to offer, which is not noted.
        var loadJournal: URL? = nil
        /// Where macOS keeps resource (`.diag`) reports for every account, and on
        /// recent releases spin and hang reports too. Only members of the
        /// `_analyticsusers` group can list it, so being unable to is noted, not
        /// an error. `nil` means the caller offers no such folder, which is not
        /// noted. `crashReports` is searched for the same kinds of report as
        /// well, since older releases wrote them there.
        var systemReports: URL? = nil
        /// What SteamCMD printed in the last runs that failed (`SteamCMDFailureLog`). Absent is the
        /// normal case and is not noted; `nil` means the caller offers none.
        var steamCMDFailures: URL? = nil
    }

    struct Limits {
        var sessions = 5
        var logBytes = 64 * 1024 * 1024
        var crashReports = 5
        var crashReportAge: TimeInterval = 14 * 24 * 60 * 60
        /// Resource, spin and hang reports across both report folders. They
        /// share `crashReportAge`.
        var resourceReports = 5
        /// A report over this many bytes contributes its tail.
        var resourceReportBytes = 4 * 1024 * 1024
    }

    struct Report: Equatable {
        var included: [String]
        var missing: [String]
    }

    var sources: Sources
    var limits = Limits()
    var redactor: DiagnosticsRedactor

    /// The file the bridge keeps beside `config.toml`.
    static let loadJournalFileName = "load-journal.json"

    static func sources(
        logsRoot: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        supportRoot: URL = ClientPaths.supportURL,
        systemReports: URL = URL(fileURLWithPath: "/Library/Logs/DiagnosticReports", isDirectory: true)
    ) -> Sources {
        Sources(
            logsRoot: logsRoot,
            extensionLog: home.appending(path: LockScreenConfiguration.exchangeRelativePath).appending(path: "extension.log"),
            crashReports: CrashReportIndex.userReportsFolder(home: home),
            loadJournal: supportRoot.appending(path: loadJournalFileName),
            systemReports: systemReports,
            steamCMDFailures: supportRoot.appending(path: SteamCMDFailureLog.fileName))
    }

    /// Local time, POSIX locale, so the name sorts and does not pick up a
    /// 12-hour clock from the user's region.
    static func suggestedFileName(at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "WallpaperMachine-diagnostics-\(formatter.string(from: date)).zip"
    }

    func export(to destination: URL, environment: [String], at date: Date) throws -> Report {
        let stem = Self.stem(at: date)
        // The coordinated item has to be named the stem: that name is the
        // folder inside the zip. A unique parent keeps a second export in the
        // same second from sharing, or deleting, this staging directory.
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagnostics-export-\(UUID().uuidString)", isDirectory: true)
        let staging = parent.appendingPathComponent(stem, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        var included: [String] = []
        var missing: [String] = []
        try collectLogs(into: staging, included: &included, missing: &missing)
        try collectExtensionLog(into: staging, included: &included, missing: &missing)
        try collectLoadJournal(into: staging, included: &included, missing: &missing)
        try collectSteamCMDFailures(into: staging, included: &included)
        try collectCrashReports(into: staging, at: date, included: &included, missing: &missing)
        try collectResourceReports(into: staging, at: date, included: &included, missing: &missing)
        try write(
            redactor.redact(environment.joined(separator: "\n") + "\n"),
            to: staging.appendingPathComponent("environment.txt"))
        included.append("environment.txt")
        included.append("README.txt")
        included.sort()
        try write(readme(included: included, missing: missing, at: date), to: staging.appendingPathComponent("README.txt"))

        try zip(staging, to: destination)
        return Report(included: included, missing: missing.map { redactor.redact($0) })
    }

    private static func stem(at date: Date) -> String {
        let name = suggestedFileName(at: date)
        return name.hasSuffix(".zip") ? String(name.dropLast(4)) : name
    }

    private func collectLogs(into staging: URL, included: inout [String], missing: inout [String]) throws {
        let directories: [URL]
        do {
            directories = try FileManager.default.contentsOfDirectory(
                at: sources.logsRoot,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [])
        } catch {
            missing.append("application logs were not readable")
            return
        }
        let sessions = directories.compactMap { url -> (url: URL, rank: SessionRank)? in
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true,
                  values.isSymbolicLink != true
            else { return nil }
            return (url, SessionRank(name: url.lastPathComponent))
        }.sorted { $0.rank > $1.rank }
        guard !sessions.isEmpty else {
            missing.append("no application log sessions")
            return
        }

        let chosen = sessions.prefix(max(limits.sessions, 0))
        for session in sessions.dropFirst(chosen.count) {
            missing.append("session \(session.rank.name) omitted: only the \(limits.sessions) newest sessions are included")
        }

        var budget = limits.logBytes
        for session in chosen {
            try collectSession(session.url, name: session.rank.name, budget: &budget, into: staging, included: &included, missing: &missing)
        }
    }

    private func collectSession(
        _ url: URL,
        name: String,
        budget: inout Int,
        into staging: URL,
        included: inout [String],
        missing: inout [String]
    ) throws {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [])) ?? []
        let logs = files.compactMap { file -> (url: URL, generation: Int)? in
            guard let generation = Self.logGeneration(file.lastPathComponent),
                  (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { return nil }
            return (file, generation)
        }.sorted { lhs, rhs in
            if lhs.generation != rhs.generation { return lhs.generation > rhs.generation }
            return lhs.url.lastPathComponent < rhs.url.lastPathComponent
        }
        for file in logs {
            let relative = "logs/\(name)/\(file.url.lastPathComponent)"
            if budget <= 0 {
                missing.append("\(relative) omitted: log size limit reached")
                continue
            }
            let slice: LogSlice
            do {
                slice = try Self.readLog(file.url, limit: budget)
            } catch {
                missing.append("\(relative) could not be read")
                continue
            }
            var text = redactor.redact(slice.text)
            if slice.omitted > 0 {
                text = "[truncated: first \(slice.omitted) bytes omitted]\n" + text
            }
            try write(text, to: staging.appending(path: relative))
            included.append(relative)
            budget = slice.omitted > 0 ? 0 : budget - slice.rawBytes
        }
    }

    private func collectExtensionLog(into staging: URL, included: inout [String], missing: inout [String]) throws {
        let relative = "lock-screen/extension.log"
        do {
            let data = try Data(contentsOf: sources.extensionLog)
            try write(redactor.redact(String(decoding: data, as: UTF8.self)), to: staging.appending(path: relative))
            included.append(relative)
        } catch {
            missing.append("\(relative) was not readable")
        }
    }

    /// Which wallpapers the app was opening when it died, and how often. Absent
    /// is normal: the file exists only once a scene has been opened, so it is a
    /// note, and the rest of the report is unaffected.
    private func collectLoadJournal(into staging: URL, included: inout [String], missing: inout [String]) throws {
        guard let source = sources.loadJournal else { return }
        let relative = Self.loadJournalFileName
        let data: Data
        do {
            data = try Data(contentsOf: source)
        } catch {
            let absent = (error as? CocoaError)?.code == .fileReadNoSuchFile
            missing.append("\(relative) was not \(absent ? "present" : "readable")")
            return
        }
        try write(redactor.redact(String(decoding: data, as: UTF8.self)), to: staging.appending(path: relative))
        included.append(relative)
    }

    /// Redacted when SteamCMD printed it, and once more here like every other file.
    private func collectSteamCMDFailures(into staging: URL, included: inout [String]) throws {
        guard let source = sources.steamCMDFailures,
              let text = SteamCMDFailureLog(url: source).read() else { return }
        let relative = "steamcmd-failures.txt"
        try write(redactor.redact(text + "\n"), to: staging.appending(path: relative))
        included.append(relative)
    }

    private func collectCrashReports(
        into staging: URL,
        at date: Date,
        included: inout [String],
        missing: inout [String]
    ) throws {
        let matches: [ReportFile]
        do {
            matches = try reportFiles(in: sources.crashReports, extensions: ["ips"], at: date).sorted(by: ReportFile.newestFirst)
        } catch {
            missing.append(crashReportWindowNote)
            return
        }
        guard !matches.isEmpty else {
            missing.append(crashReportWindowNote)
            return
        }
        for report in matches.prefix(max(limits.crashReports, 0)) {
            let relative = "crash-reports/\(report.url.lastPathComponent)"
            do {
                let data = try Data(contentsOf: report.url)
                try write(redactor.redact(String(decoding: data, as: UTF8.self)), to: staging.appending(path: relative))
                included.append(relative)
            } catch {
                missing.append("\(relative) could not be read")
            }
        }
    }

    /// The reports macOS writes when the app uses too much CPU or disk, or
    /// stops responding. They name the code that was running, which a crash
    /// report cannot do for a process that never crashed.
    ///
    /// Classified by file name only. The body differs between macOS releases
    /// and is never parsed, only redacted.
    private func collectResourceReports(
        into staging: URL,
        at date: Date,
        included: inout [String],
        missing: inout [String]
    ) throws {
        var matches: [ReportFile] = []
        // The per-account folder is searched without a note: a missing or empty
        // one is the normal case on a release that writes everything system-wide.
        if let found = try? reportFiles(in: sources.crashReports, extensions: Self.resourceReportExtensions, at: date) {
            matches += found
        }
        var systemUnreadable = false
        if let system = sources.systemReports {
            do {
                matches += try reportFiles(in: system, extensions: Self.resourceReportExtensions, at: date)
            } catch {
                systemUnreadable = true
            }
        }
        if systemUnreadable {
            missing.append("macOS resource reports were not readable (the account may not be in the _analyticsusers group)")
        } else if matches.isEmpty {
            missing.append("no resource, spin or hang reports in the last \(reportAgeDays) days")
        }

        var names = Set<String>()
        for report in matches.sorted(by: ReportFile.newestFirst).prefix(max(limits.resourceReports, 0)) {
            let relative = "diagnostic-reports/" + uniqueReportName(report.url.lastPathComponent, taken: &names)
            let slice: LogSlice
            do {
                slice = try Self.readLog(report.url, limit: limits.resourceReportBytes)
            } catch {
                missing.append("\(relative) could not be read")
                continue
            }
            var text = redactor.redact(slice.text)
            if slice.omitted > 0 {
                text = "[truncated: first \(slice.omitted) bytes omitted]\n" + text
            }
            try write(text, to: staging.appending(path: relative))
            included.append(relative)
        }
    }

    private static let resourceReportExtensions: Set<String> = ["diag", "spin", "hang"]

    private struct ReportFile {
        var url: URL
        var modified: Date

        static func newestFirst(_ lhs: Self, _ rhs: Self) -> Bool {
            if lhs.modified != rhs.modified { return lhs.modified > rhs.modified }
            return lhs.url.lastPathComponent < rhs.url.lastPathComponent
        }
    }

    /// Regular files directly in `folder` (so `Retired/` is skipped) that belong
    /// to the app or its extension, have one of `extensions`, and were written
    /// inside the report window. Throws when the folder cannot be listed.
    private func reportFiles(in folder: URL, extensions: Set<String>, at date: Date) throws -> [ReportFile] {
        let cutoff = date.addingTimeInterval(-limits.crashReportAge)
        let files = try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [])
        return files.compactMap { url -> ReportFile? in
            guard url.lastPathComponent.hasPrefix("WallpaperMachine"),
                  extensions.contains(url.pathExtension.lowercased())
            else { return nil }
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  modified >= cutoff, modified <= date
            else { return nil }
            return ReportFile(url: url, modified: modified)
        }
    }

    /// macOS names a report `<process>_<date>_<host name>[.cpu_resource].diag`,
    /// and a Mac's host name is usually its owner's name. The redactor only
    /// knows the account's names, so the host name is dropped from the name
    /// the report is stored under. The process and the time still identify it.
    /// A name in another shape has nothing recognisable to drop and goes
    /// through the redactor instead.
    private func uniqueReportName(_ name: String, taken: inout Set<String>) -> String {
        let range = NSRange(location: 0, length: (name as NSString).length)
        let stored: String
        if let match = Self.hostNamePattern.firstMatch(in: name, range: range) {
            let ns = name as NSString
            stored = ns.substring(with: match.range(at: 1)) + ns.substring(with: match.range(at: 3))
        } else {
            stored = redactor.redact(name)
        }
        var candidate = stored
        var attempt = 1
        while !taken.insert(candidate).inserted {
            attempt += 1
            let dot = stored.firstIndex(of: ".") ?? stored.endIndex
            candidate = "\(stored[..<dot])-\(attempt)\(stored[dot...])"
        }
        return candidate
    }

    private static let hostNamePattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"^(.+_\d{4}-\d{2}-\d{2}-\d{6})_(.+?)((?:\.cpu_resource)?\.[A-Za-z]+)$"#,
            options: [])
    }()

    private var reportAgeDays: Int {
        Int(limits.crashReportAge / (24 * 60 * 60))
    }

    private var crashReportWindowNote: String {
        "no crash reports in the last \(reportAgeDays) days"
    }

    private func readme(included: [String], missing: [String], at date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let generated = formatter.string(from: date)
        let files = included.joined(separator: "\n")
        let absent = missing.isEmpty ? "(none)" : missing.joined(separator: "\n")
        return """
        Wallpaper Machine diagnostics
        Generated: \(generated)

        This archive is for a bug report. It holds the newest application log sessions that fit in the export limit, the lock-screen extension log, the load journal (which wallpapers the app was opening when it last quit unexpectedly), what SteamCMD printed in the last Steam downloads and sign-ins that failed, recent crash reports, the resource, spin and hang reports macOS wrote about the app (too much CPU or disk use, or not responding), and the environment lines supplied at export.

        Home folder paths were replaced with ~. The macOS user name was replaced with <user>. Steam account names were replaced with <account>. The Mac's host name was left out of the file names of macOS reports, and their beta program identifier was removed.

        Included:
        \(files)

        Not included:
        \(absent)
        """
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    /// Copy, don't move. The coordinator deletes its zip when the block
    /// returns, which would delete the destination if we had moved it there.
    private func zip(_ staging: URL, to destination: URL) throws {
        var coordinationError: NSError?
        var placementError: Error?
        NSFileCoordinator().coordinate(readingItemAt: staging, options: .forUploading, error: &coordinationError) { temporaryZip in
            do {
                let fm = FileManager.default
                if fm.fileExists(atPath: destination.path) {
                    try fm.removeItem(at: destination)
                }
                try fm.copyItem(at: temporaryZip, to: destination)
            } catch {
                placementError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let placementError { throw placementError }
    }

    /// `YYYYMMDD-HHMMSS` sorts chronologically. A same-second `-N` suffix sorts
    /// after the base name, and `-10` is newer than `-9`, which a plain string
    /// sort gets wrong.
    private struct SessionRank: Comparable {
        var recognized: Bool
        var stamp: String
        var generation: Int
        var name: String

        init(name: String) {
            self.name = name
            let parts = name.split(separator: "-", omittingEmptySubsequences: false)
            let dated = (parts.count == 2 || parts.count == 3)
                && Self.digits(parts[0], count: 8)
                && Self.digits(parts[1], count: 6)
                && (parts.count == 2 || Self.digits(parts[2], count: nil))
            if dated {
                recognized = true
                stamp = "\(parts[0])-\(parts[1])"
                generation = parts.count == 3 ? Int(parts[2]) ?? 0 : 0
            } else {
                recognized = false
                stamp = name
                generation = 0
            }
        }

        private static func digits(_ text: Substring, count: Int?) -> Bool {
            guard !text.isEmpty, count == nil || text.count == count else { return false }
            return text.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
        }

        static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.recognized != rhs.recognized { return !lhs.recognized }
            if lhs.stamp != rhs.stamp { return lhs.stamp < rhs.stamp }
            if lhs.generation != rhs.generation { return lhs.generation < rhs.generation }
            return lhs.name < rhs.name
        }
    }

    private struct LogSlice {
        var text: String
        var rawBytes: Int
        var omitted: Int
    }

    /// The tail is what a bug report needs. A cut that lands mid-line advances
    /// to the next newline so the included text starts on a line boundary; the
    /// omission count includes that partial line.
    private static func readLog(_ url: URL, limit: Int) throws -> LogSlice {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        guard let size = Int(exactly: end) else { throw CocoaError(.fileReadTooLarge) }
        if size <= limit {
            try handle.seek(toOffset: 0)
            let data = try handle.readToEnd() ?? Data()
            return LogSlice(text: String(decoding: data, as: UTF8.self), rawBytes: size, omitted: 0)
        }
        let start = UInt64(size - limit)
        var omitted = size - limit
        var midLine = false
        if start > 0 {
            try handle.seek(toOffset: start - 1)
            let previous = try handle.read(upToCount: 1) ?? Data()
            midLine = previous.first != 0x0A
        } else {
            try handle.seek(toOffset: 0)
        }
        var body = try handle.readToEnd() ?? Data()
        if midLine, let newline = body.firstIndex(of: 0x0A) {
            let next = body.index(newline, offsetBy: 1)
            omitted += body.distance(from: body.startIndex, to: next)
            body = body.subdata(in: next..<body.endIndex)
        }
        return LogSlice(text: String(decoding: body, as: UTF8.self), rawBytes: size, omitted: omitted)
    }

    private static func logGeneration(_ name: String) -> Int? {
        guard name.hasSuffix(".log") else { return nil }
        let stem = name.dropLast(4)
        guard !stem.isEmpty, stem.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
        return Int(stem)
    }
}
