import CryptoKit
import Foundation

actor AppUpdatePersistence {
    struct Record: Codable, Sendable {
        var format = 1
        var release: GitHubRelease?
        var archiveName: String?
        var lastCheckedAt: Date?
        var rateLimitedUntil: Date?
        var installingVersion: String?
        var recentlyInstalledVersion: String?
    }

    private let directory: URL
    private var recordURL: URL { directory.appendingPathComponent("state.json") }

    init(directory: URL) { self.directory = directory }

    func load() throws -> Record {
        if FileManager.default.fileExists(atPath: directory.path) {
            guard try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw invalidRecord }
        }
        guard FileManager.default.fileExists(atPath: recordURL.path) else { return Record() }
        let values = try recordURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= 2_000_000 else { throw invalidRecord }
        let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: recordURL))
        guard record.format == 1 else { throw invalidRecord }
        return record
    }

    func save(_ record: Record) throws {
        let data = try JSONEncoder().encode(record)
        guard data.count <= 2_000_000 else { throw invalidRecord }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw invalidRecord }
        try data.write(to: recordURL, options: .atomic)
    }

    func verifiedArchive(in record: Record) throws -> URL? {
        guard let name = record.archiveName, let release = record.release,
              let asset = GitHubReleaseParser.selectAsset(from: release) else { return nil }
        guard !name.isEmpty, name == (name as NSString).lastPathComponent,
              name != ".", name != "..", name.hasSuffix(".dmg") else { throw invalidRecord }
        let url = directory.appendingPathComponent(name)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let count = values.fileSize, count > 0, count <= AppUpdateConfiguration.maximumDownloadBytes,
              Int64(count) == asset.size, let digest = asset.digest?.lowercased(), digest.hasPrefix("sha256:")
        else { throw invalidRecord }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        var read: Int64 = 0
        while let bytes = try file.read(upToCount: 1 << 20), !bytes.isEmpty {
            try Task.checkCancellation()
            read += Int64(bytes.count)
            guard read <= asset.size else { throw invalidRecord }
            hash.update(data: bytes)
        }
        guard read == asset.size else { throw invalidRecord }
        let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == "sha256:" + actual else { throw invalidRecord }
        return url
    }

    func discardArchives(keeping: URL?) {
        guard let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink != true,
              let items = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for item in items where item.lastPathComponent != "state.json" && item.standardizedFileURL != keeping?.standardizedFileURL {
            do { try FileManager.default.removeItem(at: item) }
            catch { AppLog.warn("update cache cleanup: \(error.localizedDescription)") }
        }
    }

    private var invalidRecord: AppUpdateIssue { AppUpdateIssue(code: .verification, detail: "Invalid update cache") }
}
