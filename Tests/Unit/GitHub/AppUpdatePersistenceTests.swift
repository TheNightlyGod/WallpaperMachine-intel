import CryptoKit
import XCTest
@testable import WallpaperMachine

final class AppUpdatePersistenceTests: XCTestCase {
    func testCompletePackageSurvivesReopeningAndTamperedPackageIsRefused() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = Data("complete image".utf8)
        let image = directory.appendingPathComponent("WallpaperMachine-2.0.0-arm64.dmg")
        try bytes.write(to: image)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let asset = GitHubReleaseAsset(name: image.lastPathComponent,
            downloadURL: AppUpdateConfiguration.releasesURL, size: Int64(bytes.count), digest: "sha256:" + digest)
        let release = GitHubRelease(version: try XCTUnwrap(SemanticVersion("2.0.0")),
            htmlURL: AppUpdateConfiguration.releasesURL, prerelease: false, assets: [asset])
        let record = AppUpdatePersistence.Record(release: release, archiveName: image.lastPathComponent)
        try await AppUpdatePersistence(directory: directory).save(record)
        let reopened = AppUpdatePersistence(directory: directory)
        let loaded = try await reopened.load()
        let recovered = try await reopened.verifiedArchive(in: loaded)
        XCTAssertEqual(recovered, image)
        try Data(repeating: 0, count: bytes.count).write(to: image)
        do {
            _ = try await reopened.verifiedArchive(in: loaded)
            XCTFail("A changed package must never become ready")
        } catch { XCTAssertEqual((error as? AppUpdateIssue)?.code, .verification) }
    }

    func testCacheCleanupNeverFollowsASymbolicLinkToAnotherDirectory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outside = root.appendingPathComponent("unrelated")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let important = outside.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: important)
        let cachePath = root.appendingPathComponent("Updates")
        try FileManager.default.createSymbolicLink(at: cachePath, withDestinationURL: outside)
        let cache = AppUpdatePersistence(directory: cachePath)
        await cache.discardArchives(keeping: nil)
        XCTAssertEqual(try Data(contentsOf: important), Data("keep".utf8))
        do {
            _ = try await cache.load()
            XCTFail("A linked cache directory is not an owned update workspace")
        } catch { XCTAssertEqual((error as? AppUpdateIssue)?.code, .verification) }
    }

    func testPartialFilesAreNotRecoveredAndTraversalIsRejected() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let partial = directory.appendingPathComponent("unfinished.dmg")
        try Data("partial".utf8).write(to: partial)
        let cache = AppUpdatePersistence(directory: directory)
        let recovered = try await cache.verifiedArchive(in: cache.load())
        XCTAssertNil(recovered)
        await cache.discardArchives(keeping: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        let release = GitHubRelease(version: try XCTUnwrap(SemanticVersion("2.0.0")),
            htmlURL: AppUpdateConfiguration.releasesURL, prerelease: false,
            assets: [GitHubReleaseAsset(name: "WallpaperMachine-2.0.0-arm64.dmg", downloadURL: AppUpdateConfiguration.releasesURL, size: 1, digest: "sha256:bad")])
        do {
            _ = try await cache.verifiedArchive(in: .init(release: release, archiveName: "../outside.dmg"))
            XCTFail("Paths from a record must not escape the cache")
        } catch { XCTAssertEqual((error as? AppUpdateIssue)?.code, .verification) }
    }
}
