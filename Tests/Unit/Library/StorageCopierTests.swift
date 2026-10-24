import Darwin
import XCTest

@testable import WallpaperMachine

/// The mirror a library move copies with: a second pass copies only what changed and removes what
/// is gone, so finishing a move at launch is quick.
final class StorageCopierTests: XCTestCase {
    private var root: URL!
    private var source: URL { root.appendingPathComponent("source", isDirectory: true) }
    private var copy: URL { root.appendingPathComponent("copy", isDirectory: true) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("storage-copier-\(UUID().uuidString)", isDirectory: true)
        try put("kept", "101/scene.json")
        try put("changes", "101/project.json")
        try put("goes away", "102/movie.mp4")
        try FileManager.default.createSymbolicLink(
            atPath: source.appendingPathComponent("101/link").path, withDestinationPath: "scene.json")
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    func testSecondPassCopiesOnlyWhatChangedAndRemovesWhatIsGone() throws {
        let first = StorageCopier(tolerant: false)
        try first.mirror(source, to: copy)
        XCTAssertEqual(try read("101/scene.json", in: copy), "kept")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: copy.appendingPathComponent("101/link").path), "scene.json")
        XCTAssertEqual(first.copiedBytes, Int64("kept".utf8.count + "changes".utf8.count + "goes away".utf8.count))
        let unchanged = try inode("101/scene.json", in: copy)

        try put("changed!", "101/project.json")
        try FileManager.default.removeItem(at: source.appendingPathComponent("102"))
        try put("arrived", "103/project.json")
        let second = StorageCopier(tolerant: false)
        try second.mirror(source, to: copy)

        XCTAssertEqual(try read("101/project.json", in: copy), "changed!")
        XCTAssertEqual(try read("103/project.json", in: copy), "arrived")
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.appendingPathComponent("102").path))
        XCTAssertEqual(try inode("101/scene.json", in: copy), unchanged, "an unchanged file is not copied again")
        XCTAssertEqual(second.copiedBytes, Int64("changed!".utf8.count + "arrived".utf8.count))
        XCTAssertEqual(StorageCopier.bytes(in: [source]), Int64("kept".utf8.count + "changed!".utf8.count + "arrived".utf8.count))
    }

    func testAFolderThatBecameAFileIsReplaced() throws {
        try StorageCopier(tolerant: false).mirror(source, to: copy)
        try FileManager.default.removeItem(at: source.appendingPathComponent("102"))
        try put("now a file", "102")
        try StorageCopier(tolerant: false).mirror(source, to: copy)
        XCTAssertEqual(try read("102", in: copy), "now a file")
    }

    func testAMissingSourceRemovesTheCopy() throws {
        try StorageCopier(tolerant: false).mirror(source, to: copy)
        try FileManager.default.removeItem(at: source)
        try StorageCopier(tolerant: false).mirror(source, to: copy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
    }

    private func put(_ text: String, _ path: String) throws {
        let url = source.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ path: String, in base: URL) throws -> String {
        try String(contentsOf: base.appendingPathComponent(path), encoding: .utf8)
    }

    private func inode(_ path: String, in base: URL) throws -> UInt64 {
        var info = stat()
        guard lstat(base.appendingPathComponent(path).path, &info) == 0 else { throw POSIXError(.ENOENT) }
        return UInt64(info.st_ino)
    }
}
