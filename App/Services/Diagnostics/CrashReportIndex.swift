import Foundation

/// Finds the macOS crash report of a run the session ledger found dead.
///
/// A report is told apart by what its body says, not by its name: the process id
/// and the boot session identify the run exactly, where a name and a time window
/// could pick up another launch's report. Only the files in one folder are
/// listed and only the newest few are read.
enum CrashReportIndex {
    struct Report: Equatable {
        /// The file's name, without its folder.
        var file: String
        /// `exception.type`, such as `EXC_BAD_ACCESS`.
        var type: String?
        /// `exception.signal`, such as `SIGSEGV`.
        var signal: String?

        var summary: String { "\(file) (\(type ?? "unknown")/\(signal ?? "unknown"))" }
    }

    /// The reports of one app are named after its process.
    static let processPrefix = "WallpaperMachine"

    /// Reports read at most, newest first. A crash loop leaves many.
    static let candidateLimit = 8

    /// Larger reports are skipped: a crash report is tens of kilobytes, and a
    /// parser has no business loading something huge to find a process id.
    static let sizeLimit = 16 * 1024 * 1024

    static func userReportsFolder(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appending(path: "Library/Logs/DiagnosticReports")
    }

    /// The report written for the run with process id `pid`, or `nil` when there is
    /// none, the folder cannot be read, or the report is not there yet.
    ///
    /// A `.ips` file is a one-line header followed by the report as one JSON
    /// document. A file whose second part does not parse is passed over.
    /// - Parameters:
    ///   - bootSession: The run's `kern.bootsessionuuid`. Process ids repeat across
    ///     boots, so a report from another boot is never a match. Ignored when
    ///     either side lacks one.
    ///   - notBefore: Reports last written before this cannot belong to the run,
    ///     which started at this time.
    static func report(
        forPid pid: Int32,
        bootSession: String?,
        notBefore: Date,
        in folder: URL,
        fileManager: FileManager = .default
    ) -> Report? {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let listing = try? fileManager.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return nil }
        let candidates = listing.compactMap { url -> (url: URL, modified: Date)? in
            guard url.pathExtension == "ips", url.lastPathComponent.hasPrefix(processPrefix),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate, modified >= notBefore,
                  (values.fileSize ?? 0) <= sizeLimit else { return nil }
            return (url, modified)
        }
        .sorted { $0.modified > $1.modified }
        for candidate in candidates.prefix(candidateLimit) {
            if let report = parse(candidate.url, pid: pid, bootSession: bootSession) { return report }
        }
        return nil
    }

    private static func parse(_ url: URL, pid: Int32, bootSession: String?) -> Report? {
        guard let data = try? Data(contentsOf: url),
              let newline = data.firstIndex(of: UInt8(ascii: "\n")),
              let body = try? JSONSerialization.jsonObject(with: data[data.index(after: newline)...]) as? [String: Any],
              (body["pid"] as? NSNumber)?.int32Value == pid else { return nil }
        if let expected = bootSession, let found = body["bootSessionUUID"] as? String,
           expected.caseInsensitiveCompare(found) != .orderedSame { return nil }
        let exception = body["exception"] as? [String: Any]
        return Report(file: url.lastPathComponent, type: exception?["type"] as? String,
                      signal: exception?["signal"] as? String)
    }
}
