import Darwin
import XCTest
@testable import WallpaperMachine

final class ImportTests: XCTestCase {
    private var root: URL!
    private var library: URL { root.appendingPathComponent("managed/Library") }
    private let importer = WallpaperImportService()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("WallpaperMachine-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func project(_ id: String, file: String = "movie.mp4", type: String = "video") throws -> URL {
        let url = root.appendingPathComponent("sources/\(id)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("video-content".utf8).write(to: url.appendingPathComponent("movie.mp4"))
        try JSONSerialization.data(withJSONObject: ["title": "Test \(id)", "type": type, "file": file])
            .write(to: url.appendingPathComponent("project.json"))
        return url
    }
    private func importOne(_ url: URL, policy: WallpaperImportService.DuplicatePolicy = .skip) async throws -> WallpaperImportService.Report {
        try await importer.importItems([url], into: library, duplicates: policy, progress: { _ in })
    }

    private func downloadedProject(_ id: String, staging: URL) throws -> URL {
        let source = try project(id)
        let destination = staging.appendingPathComponent("steamapps/workshop/content/431960/\(id)")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: source, to: destination)
        return destination
    }

    private func assertDownloadRejected(_ id: String, staging: URL, library destination: URL? = nil,
                                        file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await importer.importDownloadedItem(id, from: staging, into: destination ?? library)
            XCTFail("Unsafe or incomplete download was accepted", file: file, line: line)
        } catch {}
    }

    func testImportPreservesOriginalAndCompleteContent() async throws {
        let source = try project("123456")
        let report = try await importOne(source)
        XCTAssertEqual(report.importedIDs, ["123456"])
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("movie.mp4")),
                       try Data(contentsOf: library.appendingPathComponent("123456/movie.mp4")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.appendingPathComponent("123456/project.json").path))
    }
    func testDuplicatesNeverOverwriteExistingWallpaper() async throws {
        let source = try project("123456")
        _ = try await importOne(source)
        try Data("different-content".utf8).write(to: source.appendingPathComponent("movie.mp4"))
        let skipped = try await importOne(source)
        XCTAssertEqual(skipped.skipped, ["123456"])
        XCTAssertEqual(try String(contentsOf: library.appendingPathComponent("123456/movie.mp4"), encoding: .utf8), "video-content")
        let kept = try await importOne(source, policy: .keepBoth)
        XCTAssertEqual(kept.importedIDs.count, 1)
        XCTAssertNotEqual(kept.importedIDs.first, "123456")
        XCTAssertEqual(try String(contentsOf: library.appendingPathComponent("\(try XCTUnwrap(kept.importedIDs.first))/movie.mp4"), encoding: .utf8), "different-content")
    }
    func testTraversalProjectIsRejectedWithoutLibraryEntry() async throws {
        let source = try project("escape", file: "../movie.mp4")
        let report = try await importOne(source)
        XCTAssertTrue(report.importedIDs.isEmpty)
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.appendingPathComponent("escape").path))
    }
    func testSymlinkContentIsRejectedWithoutPartialCommit() async throws {
        let source = try project("link")
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("outside"), withDestinationURL: root)
        let report = try await importOne(source)
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertTrue(report.importedIDs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.appendingPathComponent("link").path))
    }
    func testInvalidProjectDoesNotPreventValidSiblingImport() async throws {
        let invalid = try project("invalid", file: "missing.mp4")
        let valid = try project("valid")
        let result = try await importer.importItems([invalid, valid], into: library, duplicates: .skip, progress: { _ in })
        XCTAssertEqual(result.importedIDs, ["valid"])
        XCTAssertEqual(result.failures.count, 1)
    }
    func testImportFromManagedLibraryRejected() async throws {
        let source = try project("123")
        _ = try await importOne(source)
        let result = try await importOne(library.appendingPathComponent("123"), policy: .keepBoth)
        XCTAssertTrue(result.importedIDs.isEmpty)
        XCTAssertEqual(result.failures.count, 1)
    }
    func testCancellationNeverCommitsIncompleteProject() async throws {
        let source = try project("cancelled")
        let task = Task {
            try await importer.importItems([source], into: library, duplicates: .skip, progress: { _ in })
        }
        task.cancel()
        let report = try await task.value
        XCTAssertTrue(report.cancelled)
        XCTAssertTrue(report.importedIDs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.appendingPathComponent("cancelled").path))
    }
    func testStandaloneVideoProducesPlayableManifest() async throws {
        let video = root.appendingPathComponent("My Video.mp4")
        try Data("video-content".utf8).write(to: video)
        let result = try await importOne(video)
        let id = try XCTUnwrap(result.importedIDs.first)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: library.appendingPathComponent("\(id)/project.json"))) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "video")
        XCTAssertEqual(json["file"] as? String, "My Video.mp4")
        XCTAssertEqual(try Data(contentsOf: library.appendingPathComponent("\(id)/My Video.mp4")), try Data(contentsOf: video))
    }

    func testInvalidExistingDestinationIsNotReportedInstalled() async throws {
        let source = try project("123")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try Data("not a wallpaper".utf8).write(to: library.appendingPathComponent("123"))
        let result = try await importOne(source)
        XCTAssertTrue(result.skipped.isEmpty)
        XCTAssertTrue(result.importedIDs.isEmpty)
        XCTAssertEqual(result.failures.count, 1)
    }

    func testByteOrderMarkedManifestIsRejectedBeforeCommit() async throws {
        let source = try project("bom")
        let manifest = source.appendingPathComponent("project.json")
        let original = try Data(contentsOf: manifest)
        try (Data([0xEF, 0xBB, 0xBF]) + original).write(to: manifest)
        let result = try await importOne(source)
        XCTAssertTrue(result.importedIDs.isEmpty)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.appendingPathComponent("bom").path))
    }

    func testDownloadedProjectMovesCompleteTreeWithoutCopying() async throws {
        let staging = root.appendingPathComponent("download")
        let source = try downloadedProject("123", staging: staging)
        let nested = source.appendingPathComponent("assets/nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let payload = nested.appendingPathComponent("texture.bin")
        try Data("nested-content".utf8).write(to: payload)
        let originalIdentity = try FileManager.default.attributesOfItem(atPath: payload.path)[.systemFileNumber] as? NSNumber
        try await importer.importDownloadedItem("123", from: staging, into: library)
        let installed = library.appendingPathComponent("123/assets/nested/texture.bin")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: installed), Data("nested-content".utf8))
        XCTAssertEqual(try XCTUnwrap(originalIdentity),
                       try XCTUnwrap(FileManager.default.attributesOfItem(atPath: installed.path)[.systemFileNumber] as? NSNumber))
        XCTAssertEqual(try Data(contentsOf: library.appendingPathComponent("123/movie.mp4")), Data("video-content".utf8))
    }

    func testDownloadedUnsafeTreesNeverPublishPartialItems() async throws {
        for (id, specialFile) in [("123", false), ("124", true)] {
            let staging = root.appendingPathComponent("download-\(id)")
            let source = try downloadedProject(id, staging: staging)
            let nested = source.appendingPathComponent(".hidden/nested")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            let unsafe = nested.appendingPathComponent("unsafe")
            if specialFile {
                XCTAssertEqual(unsafe.withUnsafeFileSystemRepresentation { mkfifo($0!, mode_t(0o600)) }, 0)
            } else {
                try FileManager.default.createSymbolicLink(at: unsafe, withDestinationURL: root.appendingPathComponent("missing"))
            }
            await assertDownloadRejected(id, staging: staging)
            XCTAssertFalse(FileManager.default.fileExists(atPath: library.appendingPathComponent(id).path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("movie.mp4").path))
        }
    }

    func testDownloadedFixedAncestorsCannotTraverseSymbolicLinks() async throws {
        for component in ["", "steamapps", "steamapps/workshop", "steamapps/workshop/content", "steamapps/workshop/content/431960", "steamapps/workshop/content/431960/123"] {
            let staging = root.appendingPathComponent(UUID().uuidString)
            _ = try downloadedProject("123", staging: staging)
            let ancestor = component.isEmpty ? staging : staging.appendingPathComponent(component)
            let original = root.appendingPathComponent(UUID().uuidString)
            try FileManager.default.moveItem(at: ancestor, to: original)
            try FileManager.default.createSymbolicLink(at: ancestor, withDestinationURL: original)
            await assertDownloadRejected("123", staging: staging)
            XCTAssertFalse(FileManager.default.fileExists(atPath: library.appendingPathComponent("123").path))
        }
    }

    func testDownloadedIncompleteContentNeverPublishes() async throws {
        for (id, damage) in [("123", "manifest"), ("124", "missing"), ("125", "empty")] {
            let staging = root.appendingPathComponent("download-\(id)")
            let source = try downloadedProject(id, staging: staging)
            switch damage {
            case "manifest":
                try Data("{\"type\":".utf8).write(to: source.appendingPathComponent("project.json"))
            case "missing":
                try FileManager.default.removeItem(at: source.appendingPathComponent("movie.mp4"))
            default:
                try Data().write(to: source.appendingPathComponent("movie.mp4"))
            }
            await assertDownloadRejected(id, staging: staging)
            XCTAssertFalse(FileManager.default.fileExists(atPath: library.appendingPathComponent(id).path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        }
    }

    func testDownloadedCancellationPreservesStagedContent() async throws {
        let staging = root.appendingPathComponent("download")
        let source = try downloadedProject("123", staging: staging)
        let importer = self.importer
        let library = self.library
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await importer.importDownloadedItem("123", from: staging, into: library)
        }
        do {
            try await task.value
            XCTFail("Cancelled download was published")
        } catch is CancellationError {
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.appendingPathComponent("123").path))
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("movie.mp4")), Data("video-content".utf8))
    }

    func testDownloadedDuplicatePreservesExistingAndStagedContent() async throws {
        let source = try project("123")
        _ = try await importOne(source)
        try FileManager.default.removeItem(at: source)
        let staging = root.appendingPathComponent("download")
        let downloaded = try downloadedProject("123", staging: staging)
        try Data("replacement".utf8).write(to: downloaded.appendingPathComponent("movie.mp4"))
        try await importer.importDownloadedItem("123", from: staging, into: library)
        XCTAssertEqual(try Data(contentsOf: library.appendingPathComponent("123/movie.mp4")), Data("video-content".utf8))
        XCTAssertEqual(try Data(contentsOf: downloaded.appendingPathComponent("movie.mp4")), Data("replacement".utf8))
    }

    func testDownloadedInvalidOrLinkedExistingDestinationIsRejected() async throws {
        let staging = root.appendingPathComponent("download")
        let source = try downloadedProject("123", staging: staging)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let destination = library.appendingPathComponent("123")
        try Data("existing-invalid".utf8).write(to: destination)
        await assertDownloadRejected("123", staging: staging)
        XCTAssertEqual(try Data(contentsOf: destination), Data("existing-invalid".utf8))
        try FileManager.default.removeItem(at: destination)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: source)
        await assertDownloadRejected("123", staging: staging)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination.path), source.path)
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("movie.mp4")), Data("video-content".utf8))
    }

    func testDownloadedInvalidIDsAndOverlappingRootsAreRejected() async throws {
        let staging = root.appendingPathComponent("download")
        let source = try downloadedProject("123", staging: staging)
        for invalid in ["../123", "+123", "0", "１２３", "18446744073709551616"] {
            await assertDownloadRejected(invalid, staging: staging)
        }
        await assertDownloadRejected("123", staging: staging, library: staging)
        await assertDownloadRejected("123", staging: staging, library: staging.appendingPathComponent("managed"))
        await assertDownloadRejected("123", staging: staging, library: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.appendingPathComponent("123").path))
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("movie.mp4")), Data("video-content".utf8))
    }

    func testDownloadedUpdateReplacesTheInstalledTreeAndLeavesTheOldInStaging() async throws {
        let firstStaging = root.appendingPathComponent("download-first")
        _ = try downloadedProject("123", staging: firstStaging)
        try await importer.importDownloadedItem("123", from: firstStaging, into: library)
        let updateStaging = root.appendingPathComponent("download-update")
        let update = try downloadedProject("123", staging: updateStaging)
        try Data("updated-content".utf8).write(to: update.appendingPathComponent("movie.mp4"))

        try await importer.importDownloadedItem("123", from: updateStaging, into: library, replacing: true)
        XCTAssertEqual(try Data(contentsOf: library.appendingPathComponent("123/movie.mp4")), Data("updated-content".utf8))
        // The old tree is swapped into staging, which the downloader clears with the rest of it.
        XCTAssertEqual(try Data(contentsOf: update.appendingPathComponent("movie.mp4")), Data("video-content".utf8))
    }

    /// The replaced tree goes to staging, which is cleared, so only an installed wallpaper may go.
    func testAnUpdateLeavesAFolderThatIsNotAnInstalledWallpaperAlone() async throws {
        let folder = library.appendingPathComponent("789")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: folder.appendingPathComponent("notes.txt"))
        let staging = root.appendingPathComponent("download-update")
        let update = try downloadedProject("789", staging: staging)
        do {
            try await importer.importDownloadedItem("789", from: staging, into: library, replacing: true)
            XCTFail("a folder that is not an installed wallpaper must not be replaced")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("notes.txt")), Data("keep".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("project.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: update.appendingPathComponent("project.json").path))
    }

    /// A reinstall repairs a copy that no longer plays: one missing its entry file, or whose manifest
    /// does not parse, is swapped out for the download, and the broken tree ends up in staging.
    func testReplacingADamagedInstalledProjectPublishesTheDownload() async throws {
        let damages: [(id: String, damage: (URL) throws -> Void, leftBehind: (URL) -> Bool)] = [
            ("321", { try FileManager.default.removeItem(at: $0.appendingPathComponent("movie.mp4")) },
             { !FileManager.default.fileExists(atPath: $0.appendingPathComponent("movie.mp4").path) }),
            ("322", { try Data("{ not json".utf8).write(to: $0.appendingPathComponent("project.json")) },
             { (try? Data(contentsOf: $0.appendingPathComponent("project.json"))) == Data("{ not json".utf8) }),
        ]
        for (id, damage, leftBehind) in damages {
            let first = root.appendingPathComponent("download-first-\(id)")
            _ = try downloadedProject(id, staging: first)
            try await importer.importDownloadedItem(id, from: first, into: library)
            try damage(library.appendingPathComponent(id))

            let staging = root.appendingPathComponent("download-reinstall-\(id)")
            let download = try downloadedProject(id, staging: staging)
            try Data("reinstalled".utf8).write(to: download.appendingPathComponent("movie.mp4"))
            try await importer.importDownloadedItem(id, from: staging, into: library, replacing: true)

            let installed = library.appendingPathComponent(id)
            XCTAssertEqual(try Data(contentsOf: installed.appendingPathComponent("movie.mp4")), Data("reinstalled".utf8), id)
            let manifest = try XCTUnwrap(JSONSerialization.jsonObject(
                with: Data(contentsOf: installed.appendingPathComponent("project.json"))) as? [String: Any])
            XCTAssertEqual(manifest["type"] as? String, "video", id)
            XCTAssertTrue(leftBehind(download), "The damaged tree goes to staging whole, not deleted first: \(id)")
        }
    }

    /// The least a replaceable folder holds is a project.json of its own: a link in its place is
    /// somebody else's file, and the folder stays where it is.
    func testAReplacementNeverTakesAFolderWhoseManifestIsALink() async throws {
        let folder = library.appendingPathComponent("788")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let elsewhere = root.appendingPathComponent("elsewhere.json")
        try Data("{}".utf8).write(to: elsewhere)
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent("project.json"), withDestinationURL: elsewhere)
        let staging = root.appendingPathComponent("download-reinstall")
        let download = try downloadedProject("788", staging: staging)
        do {
            try await importer.importDownloadedItem("788", from: staging, into: library, replacing: true)
            XCTFail("a folder without a project.json of its own must not be replaced")
        } catch {}
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(
            atPath: folder.appendingPathComponent("project.json").path), elsewhere.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: download.appendingPathComponent("movie.mp4").path))
    }

    func testReplacingWithNothingInstalledStillPublishes() async throws {
        let staging = root.appendingPathComponent("download-new")
        _ = try downloadedProject("456", staging: staging)
        try await importer.importDownloadedItem("456", from: staging, into: library, replacing: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.appendingPathComponent("456/project.json").path))
    }

    func testConcurrentDownloadedPublicationsKeepOneWholeProject() async throws {
        let firstStaging = root.appendingPathComponent("download-first")
        let secondStaging = root.appendingPathComponent("download-second")
        let first = try downloadedProject("123", staging: firstStaging)
        let second = try downloadedProject("123", staging: secondStaging)
        try Data("second-content".utf8).write(to: second.appendingPathComponent("movie.mp4"))
        try Data("first".utf8).write(to: first.appendingPathComponent("marker"))
        try Data("second".utf8).write(to: second.appendingPathComponent("marker"))
        let otherImporter = WallpaperImportService()
        async let firstImport: Void = importer.importDownloadedItem("123", from: firstStaging, into: library)
        async let secondImport: Void = otherImporter.importDownloadedItem("123", from: secondStaging, into: library)
        _ = try await (firstImport, secondImport)
        let firstRemains = FileManager.default.fileExists(atPath: first.path)
        let secondRemains = FileManager.default.fileExists(atPath: second.path)
        XCTAssertNotEqual(firstRemains, secondRemains)
        XCTAssertEqual(try Data(contentsOf: library.appendingPathComponent("123/movie.mp4")),
                       Data((firstRemains ? "second-content" : "video-content").utf8))
        XCTAssertEqual(try Data(contentsOf: library.appendingPathComponent("123/marker")),
                       Data((firstRemains ? "second" : "first").utf8))
    }

    // MARK: Workshop presets

    /// A web wallpaper with two properties, as a Workshop preset's base.
    private func presetBase(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("<html></html>".utf8).write(to: url.appendingPathComponent("index.html"))
        try Data("base-preview".utf8).write(to: url.appendingPathComponent("preview.jpg"))
        let manifest: [String: Any] = [
            "title": "Fluid", "type": "web", "file": "index.html", "preview": "preview.jpg", "workshopid": "100",
            "general": ["supportsaudioprocessing": true, "properties": [
                "speed": ["type": "slider", "value": 1],
                "backgroundimage": ["type": "file", "value": ""],
                "group": ["type": "group"],
            ]],
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: url.appendingPathComponent("project.json"))
    }

    /// A Workshop preset of item 100: no type, its own preview and a picture its values point at.
    private func preset(at url: URL, dependency: Any = "100") throws {
        try FileManager.default.createDirectory(at: url.appendingPathComponent("files"), withIntermediateDirectories: true)
        try Data("preset-preview".utf8).write(to: url.appendingPathComponent("preview.gif"))
        try Data("picture".utf8).write(to: url.appendingPathComponent("files/bg.png"))
        let manifest: [String: Any] = [
            "title": "Purple Ink", "dependency": dependency, "preview": "preview.gif", "workshopid": "200",
            "preset": ["speed": 7, "backgroundimage": "files/bg.png", "group": NSNull(), "undeclared": 3],
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: url.appendingPathComponent("project.json"))
    }

    private func content(_ staging: URL, _ id: String) -> URL {
        staging.appendingPathComponent("steamapps/workshop/content/431960/\(id)")
    }

    private func assertAssembledPreset(_ id: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let installed = library.appendingPathComponent(id)
        XCTAssertEqual(try Data(contentsOf: installed.appendingPathComponent("index.html")), Data("<html></html>".utf8), file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: installed.appendingPathComponent("files/bg.png")), Data("picture".utf8), file: file, line: line)
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: installed.appendingPathComponent("project.json"))) as? [String: Any])
        XCTAssertEqual(manifest["type"] as? String, "web", file: file, line: line)
        XCTAssertEqual(manifest["file"] as? String, "index.html", file: file, line: line)
        XCTAssertEqual(manifest["title"] as? String, "Purple Ink", file: file, line: line)
        XCTAssertEqual(manifest["preview"] as? String, "preview.gif", file: file, line: line)
        XCTAssertEqual(manifest["workshopid"] as? String, "200", file: file, line: line)
        XCTAssertEqual(manifest["dependency"] as? String, "100", file: file, line: line)
        let general = try XCTUnwrap(manifest["general"] as? [String: Any])
        XCTAssertEqual(general["supportsaudioprocessing"] as? Bool, true, file: file, line: line)
        let properties = try XCTUnwrap(general["properties"] as? [String: [String: Any]])
        XCTAssertEqual(properties["speed"]?["value"] as? Int, 7, file: file, line: line)
        XCTAssertEqual(properties["backgroundimage"]?["value"] as? String, "files/bg.png", file: file, line: line)
        XCTAssertNil(properties["group"]?["value"], "A heading takes no value", file: file, line: line)
        XCTAssertNil(properties["undeclared"], "Only the base's own properties take values", file: file, line: line)
    }

    func testDownloadedPresetIsAssembledOnTheBaseDownloadedWithIt() async throws {
        let staging = root.appendingPathComponent("download-preset")
        try preset(at: content(staging, "200"))
        let found = try await importer.presetBaseToDownload("200", in: staging, library: library)
        XCTAssertEqual(found, "100")
        try presetBase(at: content(staging, "100"))
        let fetched = try await importer.presetBaseToDownload("200", in: staging, library: library)
        XCTAssertNil(fetched, "A base already in staging is not fetched again")
        try await importer.importDownloadedItem("200", from: staging, into: library)
        try assertAssembledPreset("200")
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.appendingPathComponent("100").path))
    }

    func testDownloadedPresetReusesAnInstalledBaseWithoutChangingIt() async throws {
        try presetBase(at: library.appendingPathComponent("100"))
        let original = try Data(contentsOf: library.appendingPathComponent("100/project.json"))
        let staging = root.appendingPathComponent("download-preset")
        try preset(at: content(staging, "200"), dependency: 100)
        let found = try await importer.presetBaseToDownload("200", in: staging, library: library)
        XCTAssertNil(found)
        try await importer.importDownloadedItem("200", from: staging, into: library, replacing: true)
        try assertAssembledPreset("200")
        XCTAssertEqual(try Data(contentsOf: library.appendingPathComponent("100/project.json")), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.appendingPathComponent("100/files").path))
    }

    func testOrdinaryDownloadNeedsNoBase() async throws {
        let staging = root.appendingPathComponent("download")
        _ = try downloadedProject("123", staging: staging)
        let found = try await importer.presetBaseToDownload("123", in: staging, library: library)
        XCTAssertNil(found)
    }

    func testPresetWithoutAUsableBaseIsNeverPublished() async throws {
        let missing = root.appendingPathComponent("download-missing")
        try preset(at: content(missing, "200"))
        await assertDownloadRejected("200", staging: missing)
        let nested = root.appendingPathComponent("download-nested")
        try preset(at: content(nested, "200"))
        try preset(at: content(nested, "100"), dependency: "50")
        await assertDownloadRejected("200", staging: nested)
        let itself = root.appendingPathComponent("download-itself")
        try preset(at: content(itself, "200"), dependency: "200")
        do {
            _ = try await importer.presetBaseToDownload("200", in: itself, library: library)
            XCTFail("A preset of itself has no base to fetch")
        } catch {}
        await assertDownloadRejected("200", staging: itself)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.appendingPathComponent("200").path))
    }

    func testImportedPresetIsAssembledFromItsSteamLibrarySiblingNonDestructively() async throws {
        let steamContent = root.appendingPathComponent("Steam/steamapps/workshop/content/431960")
        try presetBase(at: steamContent.appendingPathComponent("100"))
        try preset(at: steamContent.appendingPathComponent("200"))
        let report = try await importOne(steamContent.appendingPathComponent("200"))
        XCTAssertEqual(report.importedIDs, ["200"], "\(report.failures)")
        try assertAssembledPreset("200")
        XCTAssertTrue(FileManager.default.fileExists(atPath: steamContent.appendingPathComponent("200/files/bg.png").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: steamContent.appendingPathComponent("100/index.html").path))
        let orphan = root.appendingPathComponent("orphan/300")
        try preset(at: orphan)
        let failed = try await importOne(orphan)
        XCTAssertTrue(failed.importedIDs.isEmpty)
        XCTAssertEqual(failed.failures.count, 1)
    }

    // MARK: Where projects are found

    private func videoProject(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("content of \(url.lastPathComponent)".utf8).write(to: url.appendingPathComponent("movie.mp4"))
        try JSONSerialization.data(withJSONObject: ["title": url.lastPathComponent, "type": "video", "file": "movie.mp4"])
            .write(to: url.appendingPathComponent("project.json"))
    }

    private func sceneProject(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: url.appendingPathComponent("scene.json"))
        try Data("PKGV".utf8).write(to: url.appendingPathComponent("scene.pkg"))
        try JSONSerialization.data(withJSONObject: ["title": url.lastPathComponent, "type": "scene", "file": "scene.json"])
            .write(to: url.appendingPathComponent("project.json"))
    }

    /// Imports `source` into a library of its own and returns the ids it added, sorted.
    private func idsImported(from source: URL, file: StaticString = #filePath, line: UInt = #line) async throws -> [String] {
        let report = try await importer.importItems([source], into: freshLibrary(), duplicates: .skip, progress: { _ in })
        XCTAssertEqual(report.failures, [], file: file, line: line)
        return report.importedIDs.sorted()
    }

    private func freshLibrary() -> URL {
        root.appendingPathComponent("libraries/\(UUID().uuidString)/Library")
    }

    private func assertRefused(_ source: URL, file: StaticString = #filePath, line: UInt = #line) async throws {
        let library = freshLibrary()
        let report = try await importer.importItems([source], into: library, duplicates: .skip, progress: { _ in })
        XCTAssertEqual(report.failures.count, 1, "\(source.path)", file: file, line: line)
        XCTAssertTrue(report.importedIDs.isEmpty, file: file, line: line)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: library.path), [], file: file, line: line)
    }

    func testAWallpaperEngineInstallInAnyChosenFolderImportsItsProjectsByFolderName() async throws {
        let steam = root.appendingPathComponent("Steam")
        let install = steam.appendingPathComponent("steamapps/common/wallpaper_engine")
        let projects = install.appendingPathComponent("projects")
        try videoProject(at: projects.appendingPathComponent("myprojects/mine-a"))
        try videoProject(at: projects.appendingPathComponent("myprojects/mine-b"))
        try videoProject(at: projects.appendingPathComponent("defaultprojects/default-a"))
        // Only project folders count: a stray folder and a file beside them are not wallpapers.
        try FileManager.default.createDirectory(at: projects.appendingPathComponent("myprojects/empty"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: projects.appendingPathComponent("myprojects/readme.txt"))

        let everything = ["default-a", "mine-a", "mine-b"]
        let selections: [(URL, [String])] = [
            (steam, everything),
            (steam.appendingPathComponent("steamapps"), everything),
            (steam.appendingPathComponent("steamapps/common"), everything),
            (install, everything),
            (projects, everything),
            (projects.appendingPathComponent("myprojects"), ["mine-a", "mine-b"]),
            (projects.appendingPathComponent("defaultprojects"), ["default-a"]),
        ]
        for (selection, expected) in selections {
            let ids = try await idsImported(from: selection)
            XCTAssertEqual(ids, expected, selection.path)
        }
        // The copy is complete, not just the manifest.
        let library = freshLibrary()
        _ = try await importer.importItems([steam], into: library, duplicates: .skip, progress: { _ in })
        XCTAssertEqual(try String(contentsOf: library.appendingPathComponent("default-a/movie.mp4"), encoding: .utf8),
                       "content of default-a")
    }

    func testACopiedWallpaperEngineFolderImportsFromItselfOrItsParent() async throws {
        let copy = root.appendingPathComponent("From my PC")
        let folder = copy.appendingPathComponent("Wallpaper Engine")
        try videoProject(at: folder.appendingPathComponent("projects/myprojects/copied-1"))
        try videoProject(at: folder.appendingPathComponent("projects/defaultprojects/copied-2"))
        for selection in [copy, folder, folder.appendingPathComponent("projects")] {
            let ids = try await idsImported(from: selection)
            XCTAssertEqual(ids, ["copied-1", "copied-2"], selection.path)
        }
    }

    func testASteamLibraryImportsItsWorkshopItemsTogetherWithWallpaperEngineProjects() async throws {
        let steam = root.appendingPathComponent("Steam/steamapps")
        try videoProject(at: steam.appendingPathComponent("workshop/content/431960/555"))
        try videoProject(at: steam.appendingPathComponent("common/wallpaper_engine/projects/myprojects/mine"))
        let ids = try await idsImported(from: root.appendingPathComponent("Steam"))
        XCTAssertEqual(ids, ["555", "mine"])
    }

    func testAProjectsFolderLinkedFromOutsideTheChosenFolderIsNotFollowed() async throws {
        let elsewhere = root.appendingPathComponent("Elsewhere")
        try videoProject(at: elsewhere.appendingPathComponent("projects/myprojects/outside"))
        // The same layout inside the chosen folder is imported.
        try videoProject(at: root.appendingPathComponent("Inside/Wallpaper Engine/projects/myprojects/inside"))
        let found = try await idsImported(from: root.appendingPathComponent("Inside"))
        XCTAssertEqual(found, ["inside"])
        let pick = root.appendingPathComponent("Pick/Wallpaper Engine")
        try FileManager.default.createDirectory(at: pick, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: pick.appendingPathComponent("projects"),
                                                   withDestinationURL: elsewhere.appendingPathComponent("projects"))
        try await assertRefused(root.appendingPathComponent("Pick"))
        try await assertRefused(pick)
    }

    func testSelectingSceneOrProjectFileImportsItsFolder() async throws {
        let scene = root.appendingPathComponent("sources/scene-100")
        try sceneProject(at: scene)
        for name in ["project.json", "scene.json", "scene.pkg"] {
            let library = freshLibrary()
            let report = try await importer.importItems(
                [scene.appendingPathComponent(name)], into: library, duplicates: .skip, progress: { _ in })
            XCTAssertEqual(report.importedIDs, ["scene-100"], "\(name): \(report.failures)")
            XCTAssertEqual(try Data(contentsOf: library.appendingPathComponent("scene-100/scene.pkg")), Data("PKGV".utf8))
        }
        // A package's extension is matched without regard to case.
        let video = root.appendingPathComponent("sources/video-200")
        try videoProject(at: video)
        try Data("PKGV".utf8).write(to: video.appendingPathComponent("extra.PKG"))
        let ids = try await idsImported(from: video.appendingPathComponent("extra.PKG"))
        XCTAssertEqual(ids, ["video-200"])
        // The folder and one of its files chosen together are one project.
        let report = try await importer.importItems(
            [scene, scene.appendingPathComponent("scene.pkg")], into: freshLibrary(), duplicates: .skip, progress: { _ in })
        XCTAssertEqual(report.importedIDs, ["scene-100"])
        XCTAssertEqual(report.failures, [])
    }

    func testProjectFileWithoutSiblingManifestIsStillRefused() async throws {
        let loose = root.appendingPathComponent("loose")
        try FileManager.default.createDirectory(at: loose, withIntermediateDirectories: true)
        for name in ["scene.json", "scene.pkg", "data.pkg"] {
            try Data("x".utf8).write(to: loose.appendingPathComponent(name))
            try await assertRefused(loose.appendingPathComponent(name))
        }
        // Any other JSON file next to a manifest is not a project file either.
        let project = root.appendingPathComponent("sources/with-extras")
        try videoProject(at: project)
        try Data("{}".utf8).write(to: project.appendingPathComponent("notes.json"))
        try await assertRefused(project.appendingPathComponent("notes.json"))
    }

    func testSymlinkedProjectFileOrParentIsRejected() async throws {
        let real = root.appendingPathComponent("sources/real")
        try sceneProject(at: real)
        let links = root.appendingPathComponent("links")
        try FileManager.default.createDirectory(at: links, withIntermediateDirectories: true)
        // The folder is a link to a project: choosing a file inside it is as refused as choosing the link.
        try FileManager.default.createSymbolicLink(at: links.appendingPathComponent("folder-link"), withDestinationURL: real)
        try await assertRefused(links.appendingPathComponent("folder-link/project.json"))
        try await assertRefused(links.appendingPathComponent("folder-link/scene.pkg"))
        // The chosen file itself is a link.
        let holder = links.appendingPathComponent("holder")
        try FileManager.default.createDirectory(at: holder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: holder.appendingPathComponent("project.json"),
                                                   withDestinationURL: real.appendingPathComponent("project.json"))
        try await assertRefused(holder.appendingPathComponent("project.json"))
        // The manifest beside a package is a link.
        let sibling = links.appendingPathComponent("sibling")
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        try Data("PKGV".utf8).write(to: sibling.appendingPathComponent("scene.pkg"))
        try FileManager.default.createSymbolicLink(at: sibling.appendingPathComponent("project.json"),
                                                   withDestinationURL: real.appendingPathComponent("project.json"))
        try await assertRefused(sibling.appendingPathComponent("scene.pkg"))
    }

    // MARK: A renamed Workshop project

    /// A video project in a folder of the given name whose manifest carries `fields`, raw JSON
    /// members such as `"workshopid": "123"`, so numbers, overflow and nonsense can be written as is.
    @discardableResult
    private func renamedProject(_ name: String, under parent: String = "sources", fields: String...) throws -> URL {
        let url = root.appendingPathComponent("\(parent)/\(name)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("content of \(name)".utf8).write(to: url.appendingPathComponent("movie.mp4"))
        let members = [#""title": "\#(name)""#, #""type": "video""#, #""file": "movie.mp4""#] + fields
        try Data("{\(members.joined(separator: ","))}".utf8).write(to: url.appendingPathComponent("project.json"))
        return url
    }

    private func importReport(of source: URL, policy: WallpaperImportService.DuplicatePolicy = .skip) async throws -> WallpaperImportService.Report {
        try await importer.importItems([source], into: freshLibrary(), duplicates: policy, progress: { _ in })
    }

    func testRenamedProjectIsFiledUnderTheWorkshopIDItsManifestNames() async throws {
        let source = try renamedProject("My Cool Wallpaper", fields: #""workshopid": "3000000001""#)
        let report = try await importOne(source)
        XCTAssertEqual(report.importedIDs, ["3000000001"], "\(report.failures)")
        XCTAssertEqual(report.recognizedWorkshopIDs, ["My Cool Wallpaper": "3000000001"])
        XCTAssertEqual(try String(contentsOf: library.appendingPathComponent("3000000001/movie.mp4"), encoding: .utf8),
                       "content of My Cool Wallpaper")
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.appendingPathComponent("My Cool Wallpaper").path))
        // A manifest that writes the id as a JSON number names it just as well.
        let numeric = try renamedProject("Number", fields: #""workshopid": 3000000002"#)
        let second = try await importReport(of: numeric)
        XCTAssertEqual(second.importedIDs, ["3000000002"])
    }

    func testRenamedProjectWithOnlyAWorkshopLinkIsRecognized() async throws {
        let links = [
            "steam://url/CommunityFilePage/3000000003",
            "https://steamcommunity.com/sharedfiles/filedetails/?id=3000000003",
            "https://steamcommunity.com/sharedfiles/filedetails/?id=3000000003&searchtext=",
        ]
        for (index, link) in links.enumerated() {
            let source = try renamedProject("Linked \(index)", fields: #""workshopurl": "\#(link)""#)
            let report = try await importReport(of: source)
            XCTAssertEqual(report.importedIDs, ["3000000003"], link)
        }
        // The id field wins when both are present.
        let both = try renamedProject("Both", fields: #""workshopid": "3000000004""#,
                                      #""workshopurl": "steam://url/CommunityFilePage/3000000005""#)
        let report = try await importReport(of: both)
        XCTAssertEqual(report.importedIDs, ["3000000004"])
    }

    func testFolderAlreadyNamedWithAnIDKeepsItsNameWhateverTheManifestSays() async throws {
        let source = try renamedProject("555", fields: #""workshopid": "999""#)
        let report = try await importOne(source)
        XCTAssertEqual(report.importedIDs, ["555"])
        XCTAssertTrue(report.recognizedWorkshopIDs.isEmpty)
    }

    func testAManifestThatNamesNoWholePositiveNumberLeavesTheFolderName() async throws {
        let unusable = [
            #""workshopid": "abc123""#, #""workshopid": "123abc""#, #""workshopid": "12 34""#, #""workshopid": " 123""#,
            #""workshopid": """#, #""workshopid": "0""#, #""workshopid": 0"#, #""workshopid": -5"#, #""workshopid": "-5""#,
            #""workshopid": "99999999999999999999""#, #""workshopid": 99999999999999999999"#,
            #""workshopid": 12.5"#, #""workshopid": 1e3"#, #""workshopid": true"#, #""workshopid": null"#,
            #""workshopid": ["123"]"#, #""workshopid": {"id": "123"}"#,
            #""workshopurl": "https://example.com/sharedfiles/filedetails/?id=123""#,
            #""workshopurl": "https://steamcommunity.com/sharedfiles/filedetails/?id=abc""#,
            #""workshopurl": "https://steamcommunity.com/sharedfiles/filedetails/?id=1&id=2""#,
            #""workshopurl": "https://steamcommunity.com/profiles/123""#,
            #""workshopurl": "steam://url/CommunityFilePage/-1""#, #""workshopurl": "steam://url/CommunityFilePage""#,
            #""workshopurl": "123""#, #""workshopurl": 123"#, #""workshopurl": """#,
        ]
        for (index, field) in unusable.enumerated() {
            let name = "Unusable \(index)"
            let report = try await importReport(of: try renamedProject(name, fields: field))
            XCTAssertEqual(report.importedIDs, [name], field)
            XCTAssertTrue(report.recognizedWorkshopIDs.isEmpty, field)
        }
        // Digits in a title are not a Workshop id, and neither is a manifest that names nothing.
        let titled = try renamedProject("Neon City 2077")
        let report = try await importReport(of: titled)
        XCTAssertEqual(report.importedIDs, ["Neon City 2077"])
    }

    func testAnUnusableIDFieldFallsBackToTheLinkNextToIt() async throws {
        let source = try renamedProject("Fallback", fields: #""workshopid": 1e3"#,
                                        #""workshopurl": "steam://url/CommunityFilePage/3000000006""#)
        let report = try await importReport(of: source)
        XCTAssertEqual(report.importedIDs, ["3000000006"])
    }

    func testARecognizedIDAlreadyInstalledFollowsTheDuplicatePolicy() async throws {
        let original = try renamedProject("3000000007", fields: #""workshopid": "3000000007""#)
        _ = try await importOne(original)
        let copy = try renamedProject("A renamed copy", fields: #""workshopid": "3000000007""#)
        try Data("edited copy".utf8).write(to: copy.appendingPathComponent("movie.mp4"))

        let skipped = try await importOne(copy)
        XCTAssertEqual(skipped.skipped, ["A renamed copy"])
        XCTAssertTrue(skipped.importedIDs.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: library.path), ["3000000007"])
        XCTAssertEqual(try String(contentsOf: library.appendingPathComponent("3000000007/movie.mp4"), encoding: .utf8),
                       "content of 3000000007", "The installed item is never replaced")

        let kept = try await importOne(copy, policy: .keepBoth)
        let keptID = try XCTUnwrap(kept.importedIDs.first)
        XCTAssertTrue(keptID.hasPrefix("3000000007-"), keptID)
        XCTAssertEqual(try String(contentsOf: library.appendingPathComponent("\(keptID)/movie.mp4"), encoding: .utf8), "edited copy")
        XCTAssertEqual(try String(contentsOf: library.appendingPathComponent("3000000007/movie.mp4"), encoding: .utf8),
                       "content of 3000000007")
    }

    func testRenamedCopiesOfOneItemInOneImportMeetTheDuplicatePolicy() async throws {
        let first = try renamedProject("First copy", fields: #""workshopid": "3000000008""#)
        let second = try renamedProject("Second copy", fields: #""workshopid": "3000000008""#)
        let report = try await importer.importItems([first, second], into: library, duplicates: .skip, progress: { _ in })
        XCTAssertEqual(report.importedIDs, ["3000000008"])
        XCTAssertEqual(report.skipped, ["Second copy"])
    }

    func testARenamedPresetIsFiledUnderItsOwnIDAndStillAssembled() async throws {
        let steamContent = root.appendingPathComponent("Steam/steamapps/workshop/content/431960")
        try presetBase(at: steamContent.appendingPathComponent("100"))
        try preset(at: steamContent.appendingPathComponent("Purple Ink"))
        let report = try await importOne(steamContent.appendingPathComponent("Purple Ink"))
        XCTAssertEqual(report.importedIDs, ["200"], "\(report.failures)")
        XCTAssertEqual(report.recognizedWorkshopIDs, ["Purple Ink": "200"])
        try assertAssembledPreset("200")
    }

    func testWorkshopLinksNameTheirItem() {
        let id = WallpaperImportService.workshopItemID(inLink:)
        XCTAssertEqual(id("steam://url/CommunityFilePage/123"), "123")
        XCTAssertEqual(id("steam://url/CommunityFilePage/123/"), "123")
        XCTAssertEqual(id("  steam://url/CommunityFilePage/123\n"), "123")
        XCTAssertEqual(id("STEAM://URL/communityfilepage/123"), "123")
        XCTAssertEqual(id("https://steamcommunity.com/sharedfiles/filedetails/?id=123"), "123")
        XCTAssertEqual(id("https://www.steamcommunity.com/sharedfiles/filedetails?id=123&searchtext=blue"), "123")
        XCTAssertEqual(id("http://steamcommunity.com/sharedfiles/filedetails/?l=english&id=123"), "123")
        XCTAssertEqual(id("steam://openurl/https://steamcommunity.com/sharedfiles/filedetails/?id=123"), "123")
        XCTAssertNil(id("https://steamcommunity.com.example.com/sharedfiles/filedetails/?id=123"))
        XCTAssertNil(id("https://example.com/sharedfiles/filedetails/?id=123"))
        XCTAssertNil(id("https://steamcommunity.com/sharedfiles/filedetails/"))
        XCTAssertNil(id("https://steamcommunity.com/sharedfiles/filedetails/?id=0"))
        XCTAssertNil(id("https://steamcommunity.com/sharedfiles/filedetails/?id=12abc"))
        XCTAssertNil(id("https://steamcommunity.com/sharedfiles/filedetails/?id=1&id=2"))
        XCTAssertNil(id("https://steamcommunity.com/app/431960/workshop/?id=123"))
        XCTAssertNil(id("steam://url/CommunityFilePage/1/2"))
        XCTAssertNil(id("steam://run/431960"))
        XCTAssertNil(id("ftp://steamcommunity.com/sharedfiles/filedetails/?id=123"))
        XCTAssertNil(id("123"))
        XCTAssertNil(id(""))
    }

    // MARK: Identical content

    /// A video project whose `movie.mp4` is a few megabytes, so comparing it takes several
    /// chunks and a change of one byte keeps its size.
    private func largeProject(_ id: String) throws -> URL {
        let url = try project(id)
        try Data(repeating: 7, count: 2 * 1024 * 1024 + 4_321).write(to: url.appendingPathComponent("movie.mp4"))
        return url
    }

    /// Imports `source` with Keep both and expects a second copy of it beside `id`, which is
    /// returned; the report names no identical project.
    @discardableResult
    private func assertKeptBeside(_ id: String, _ source: URL, file: StaticString = #filePath, line: UInt = #line) async throws -> String {
        let report = try await importOne(source, policy: .keepBoth)
        XCTAssertTrue(report.identical.isEmpty, "\(report.identical)", file: file, line: line)
        XCTAssertTrue(report.failures.isEmpty, "\(report.failures)", file: file, line: line)
        XCTAssertEqual(report.importedIDs.count, 1, file: file, line: line)
        let copy = report.importedIDs.first ?? ""
        XCTAssertTrue(copy.hasPrefix(id + "-"), copy, file: file, line: line)
        return copy
    }

    func testKeepBothNeverCopiesAProjectTheLibraryAlreadyHolds() async throws {
        let source = try project("123456")
        _ = try await importOne(source)
        let again = try await importOne(source, policy: .keepBoth)
        XCTAssertEqual(again.identical, ["123456"])
        XCTAssertEqual(again.skipped, ["123456"])
        XCTAssertTrue(again.importedIDs.isEmpty)
        XCTAssertTrue(again.failures.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: library.path), ["123456"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: library.deletingLastPathComponent().path), ["Library"],
                       "no staging copy is left behind")
    }

    func testOneChangedByteInALargeFileMakesASecondCopy() async throws {
        let source = try largeProject("big")
        _ = try await importOne(source)
        let movie = source.appendingPathComponent("movie.mp4")
        let original = try Data(contentsOf: movie)
        // The first byte, both sides of a chunk boundary, the middle and the last byte.
        for offset in [0, 1024 * 1024 - 1, 1024 * 1024, original.count / 2, original.count - 1] {
            var changed = original
            changed[offset] ^= 0xFF
            try changed.write(to: movie)
            let copy = try await assertKeptBeside("big", source)
            XCTAssertEqual(try Data(contentsOf: library.appendingPathComponent("\(copy)/movie.mp4")), changed, "offset \(offset)")
        }
        XCTAssertEqual(try Data(contentsOf: library.appendingPathComponent("big/movie.mp4")), original)
        try original.write(to: movie)
        let again = try await importOne(source, policy: .keepBoth)
        XCTAssertEqual(again.identical, ["big"], "the untouched file is still the installed one")
    }

    func testFindersFilesDoNotMakeAProjectDifferent() async throws {
        let source = try project("finder")
        try Data("one".utf8).write(to: source.appendingPathComponent(".DS_Store"))
        _ = try await importOne(source)
        // Finder rewrites its file, then it disappears from the source.
        try Data("two, and longer".utf8).write(to: source.appendingPathComponent(".DS_Store"))
        let rewritten = try await importOne(source, policy: .keepBoth)
        XCTAssertEqual(rewritten.identical, ["finder"])
        try FileManager.default.removeItem(at: source.appendingPathComponent(".DS_Store"))
        let removed = try await importOne(source, policy: .keepBoth)
        XCTAssertEqual(removed.identical, ["finder"])
        // One that only the source has, in a folder both hold.
        let nested = try project("nested")
        try FileManager.default.createDirectory(at: nested.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("note".utf8).write(to: nested.appendingPathComponent("sub/note.txt"))
        _ = try await importOne(nested)
        try Data("finder".utf8).write(to: nested.appendingPathComponent("sub/.DS_Store"))
        let added = try await importOne(nested, policy: .keepBoth)
        XCTAssertEqual(added.identical, ["nested"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: library.path).sorted(), ["finder", "nested"])
    }

    /// Choosing a file for a web wallpaper's property makes the app write its bridge into the
    /// installed folder; the project the user imports again has no such folder.
    func testTheAppsUserAssetBridgeDoesNotMakeAnInstalledProjectDifferent() async throws {
        let source = try project("123456")
        _ = try await importOne(source)
        let bridge = library.appendingPathComponent("123456/\(UserAssetStore.stagingDirectoryName)/background", isDirectory: true)
        try FileManager.default.createDirectory(at: bridge, withIntermediateDirectories: true)
        try Data("picked".utf8).write(to: bridge.appendingPathComponent("photo.png"))
        try Data("123456".utf8).write(to: bridge.deletingLastPathComponent().appendingPathComponent(UserAssetStore.ownerMarkerName))
        let installedManifest = library.appendingPathComponent("123456/project.json")
        let before = try Data(contentsOf: installedManifest)

        let kept = try await importOne(source, policy: .keepBoth)
        XCTAssertEqual(kept.identical, ["123456"])
        XCTAssertTrue(kept.importedIDs.isEmpty, "\(kept.importedIDs)")
        let replaced = try await importOne(source, policy: .replaceChanged)
        XCTAssertEqual(replaced.identical, ["123456"])
        XCTAssertTrue(replaced.importedIDs.isEmpty, "\(replaced.importedIDs)")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: library.path), ["123456"], "no second copy")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bridge.appendingPathComponent("photo.png").path),
                      "an identical project is not swapped for its own copy, so the bridge stays")
        XCTAssertEqual(try Data(contentsOf: installedManifest), before)

        // A real difference is still a difference, with the bridge in the way or not.
        try Data("video-content, longer".utf8).write(to: source.appendingPathComponent("movie.mp4"))
        try await assertKeptBeside("123456", source)
        // Only the app's folder at the top of a project is exempt: one of that name deeper is content.
        let nested = try project("nested")
        _ = try await importOne(nested)
        let hidden = nested.appendingPathComponent("sub/\(UserAssetStore.stagingDirectoryName)", isDirectory: true)
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: hidden.appendingPathComponent("file"))
        try await assertKeptBeside("nested", nested)
    }

    func testAManifestThatChangedBySameLengthIsADifferentProject() async throws {
        let source = try project("p1")
        _ = try await importOne(source)
        let manifest = source.appendingPathComponent("project.json")
        let text = try String(contentsOf: manifest, encoding: .utf8)
        let edited = text.replacingOccurrences(of: "Test p1", with: "Test p2")
        XCTAssertEqual(edited.utf8.count, text.utf8.count)
        try Data(edited.utf8).write(to: manifest)
        let copy = try await assertKeptBeside("p1", source)
        XCTAssertTrue(try String(contentsOf: library.appendingPathComponent("\(copy)/project.json"), encoding: .utf8).contains("Test p2"))
        XCTAssertTrue(try String(contentsOf: library.appendingPathComponent("p1/project.json"), encoding: .utf8).contains("Test p1"))
    }

    func testAnAddedMissingOrAlteredFileMakesASecondCopy() async throws {
        let fm = FileManager.default
        let mutations: [(String, (URL) throws -> Void)] = [
            ("an extra file", { try Data("x".utf8).write(to: $0.appendingPathComponent("extra.txt")) }),
            ("an extra empty folder", { try fm.createDirectory(at: $0.appendingPathComponent("empty"), withIntermediateDirectories: false) }),
            ("a missing file", { try fm.removeItem(at: $0.appendingPathComponent("notes.txt")) }),
            ("a missing folder", { try fm.removeItem(at: $0.appendingPathComponent("data")) }),
            ("a renamed file", { try fm.moveItem(at: $0.appendingPathComponent("notes.txt"), to: $0.appendingPathComponent("memo.txt")) }),
            ("a longer file", { try Data("notes!!".utf8).write(to: $0.appendingPathComponent("notes.txt")) }),
            ("a nested file changed by one byte", { try Data("textura".utf8).write(to: $0.appendingPathComponent("data/texture.bin")) }),
            ("a file where the library has a folder", {
                try fm.removeItem(at: $0.appendingPathComponent("data"))
                try Data("flat".utf8).write(to: $0.appendingPathComponent("data"))
            }),
        ]
        for (index, (change, mutate)) in mutations.enumerated() {
            let id = "mutation\(index)"
            let source = try project(id)
            try Data("notes".utf8).write(to: source.appendingPathComponent("notes.txt"))
            try fm.createDirectory(at: source.appendingPathComponent("data"), withIntermediateDirectories: true)
            try Data("texture".utf8).write(to: source.appendingPathComponent("data/texture.bin"))
            _ = try await importOne(source)
            let unchanged = try await importOne(source, policy: .keepBoth)
            XCTAssertEqual(unchanged.identical, [id], change)
            try mutate(source)
            try await assertKeptBeside(id, source)
        }
    }

    func testALinkIsNeverFollowedWhileComparing() async throws {
        let fm = FileManager.default
        // A link in the source: the import refuses it as it always has.
        let source = try project("link")
        _ = try await importOne(source)
        try fm.createSymbolicLink(at: source.appendingPathComponent("outside"), withDestinationURL: root)
        let refused = try await importOne(source, policy: .keepBoth)
        XCTAssertTrue(refused.identical.isEmpty)
        XCTAssertTrue(refused.importedIDs.isEmpty)
        XCTAssertEqual(refused.failures.count, 1)

        // A link in the library where the source has a file of the very bytes it points at.
        let regular = try project("planted")
        try Data("target".utf8).write(to: regular.appendingPathComponent("odd"))
        _ = try await importOne(regular)
        let installed = library.appendingPathComponent("planted/odd")
        try fm.removeItem(at: installed)
        let target = root.appendingPathComponent("target.txt")
        try Data("target".utf8).write(to: target)
        try fm.createSymbolicLink(at: installed, withDestinationURL: target)
        try await assertKeptBeside("planted", regular)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: library.path).sorted().filter { !$0.hasPrefix("planted-") }, ["link", "planted"])
    }

    func testASingleFileImportedTwiceIsCopiedOnce() async throws {
        let video = root.appendingPathComponent("My Video.mp4")
        try Data("video-content".utf8).write(to: video)
        let first = try await importOne(video)
        XCTAssertEqual(first.importedIDs, ["local-My Video.mp4"])
        let again = try await importOne(video, policy: .keepBoth)
        XCTAssertEqual(again.identical, ["My Video.mp4"])
        XCTAssertTrue(again.importedIDs.isEmpty)
        // Same size, other bytes: another video of the same name.
        try Data("video-contend".utf8).write(to: video)
        try await assertKeptBeside("local-My Video.mp4", video)

        let page = root.appendingPathComponent("Clock.html")
        try Data("<html>clock</html>".utf8).write(to: page)
        _ = try await importOne(page)
        let samePage = try await importOne(page, policy: .keepBoth)
        XCTAssertEqual(samePage.identical, ["Clock.html"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: library.path).sorted().count, 3)
    }

    func testAPresetIsNeverTakenForTheFolderItWasBuiltFrom() async throws {
        let steamContent = root.appendingPathComponent("Steam/steamapps/workshop/content/431960")
        try presetBase(at: steamContent.appendingPathComponent("100"))
        try preset(at: steamContent.appendingPathComponent("200"))
        _ = try await importOne(steamContent.appendingPathComponent("200"))
        let again = try await importOne(steamContent.appendingPathComponent("200"), policy: .keepBoth)
        XCTAssertTrue(again.identical.isEmpty)
        let copy = try XCTUnwrap(again.importedIDs.first, "\(again.failures)")
        XCTAssertTrue(copy.hasPrefix("200-"), copy)
        try assertAssembledPreset(copy)
    }

    func testAnIdenticalProjectThatIsNotAWallpaperIsStillReported() async throws {
        let source = try project("broken", file: "missing.mp4")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: library.appendingPathComponent("broken"))
        let report = try await importOne(source, policy: .keepBoth)
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertTrue(report.skipped.isEmpty)
        XCTAssertTrue(report.identical.isEmpty)
        XCTAssertTrue(report.importedIDs.isEmpty)
    }

    func testCancellingWhileComparingImportsNothing() async throws {
        let source = try largeProject("slow")
        _ = try await importOne(source)
        let task = Task {
            // The comparison is the next thing the import does after announcing the project.
            try await importer.importItems([source], into: library, duplicates: .keepBoth, progress: { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            })
        }
        let report = try await task.value
        XCTAssertTrue(report.cancelled)
        XCTAssertTrue(report.skipped.isEmpty)
        XCTAssertTrue(report.identical.isEmpty)
        XCTAssertTrue(report.importedIDs.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: library.path), ["slow"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: library.deletingLastPathComponent().path), ["Library"])
    }

    // MARK: Replace if changed

    private func names(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    private func text(_ file: URL) -> String? { try? String(contentsOf: file, encoding: .utf8) }

    private func identity(of url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int)
    }

    func testReplaceChangedPutsTheNewFilesWhereTheInstalledProjectWas() async throws {
        let source = try project("123456")
        try Data("only in the old copy".utf8).write(to: source.appendingPathComponent("old.txt"))
        _ = try await importOne(source)
        try FileManager.default.removeItem(at: source.appendingPathComponent("old.txt"))
        try Data("only in the new copy".utf8).write(to: source.appendingPathComponent("new.txt"))
        try Data("newer-content".utf8).write(to: source.appendingPathComponent("movie.mp4"))

        let report = try await importOne(source, policy: .replaceChanged)
        XCTAssertEqual(report.importedIDs, ["123456"])
        XCTAssertEqual(report.replacedIDs, ["123456"])
        XCTAssertTrue(report.skipped.isEmpty)
        XCTAssertTrue(report.failures.isEmpty, "\(report.failures)")
        let folder = library.appendingPathComponent("123456")
        XCTAssertEqual(text(folder.appendingPathComponent("movie.mp4")), "newer-content")
        XCTAssertEqual(names(in: folder), ["movie.mp4", "new.txt", "project.json"], "the old tree is gone, not merged")
        XCTAssertEqual(names(in: library), ["123456"])
        XCTAssertEqual(names(in: library.deletingLastPathComponent()), ["Library"], "no staging copy is left behind")
        XCTAssertEqual(text(source.appendingPathComponent("movie.mp4")), "newer-content", "the original is untouched")
    }

    func testReplaceChangedLeavesWhatTheLibraryAlreadyHoldsAlone() async throws {
        let source = try project("123456")
        _ = try await importOne(source)
        let installed = library.appendingPathComponent("123456")
        let before = try identity(of: installed)
        let same = try await importOne(source, policy: .replaceChanged)
        XCTAssertEqual(same.identical, ["123456"])
        XCTAssertEqual(same.skipped, ["123456"])
        XCTAssertTrue(same.replacedIDs.isEmpty)
        XCTAssertTrue(same.importedIDs.isEmpty)
        XCTAssertTrue(same.failures.isEmpty)
        XCTAssertEqual(try identity(of: installed), before, "an identical project is not swapped for its own copy")

        // Once replaced, the same source is identical to the library again.
        try Data("changed-content".utf8).write(to: source.appendingPathComponent("movie.mp4"))
        let replaced = try await importOne(source, policy: .replaceChanged)
        XCTAssertEqual(replaced.replacedIDs, ["123456"])
        let after = try identity(of: installed)
        let again = try await importOne(source, policy: .replaceChanged)
        XCTAssertEqual(again.identical, ["123456"])
        XCTAssertTrue(again.replacedIDs.isEmpty)
        XCTAssertEqual(try identity(of: installed), after)
    }

    func testReplaceChangedOnlyReplacesTheChangedProjectsOfOneImport() async throws {
        let changed = try project("100")
        let same = try project("200")
        _ = try await importer.importItems([changed, same], into: library, duplicates: .skip, progress: { _ in })
        try Data("changed-content".utf8).write(to: changed.appendingPathComponent("movie.mp4"))
        let fresh = try project("300")

        let report = try await importer.importItems([changed, same, fresh], into: library, duplicates: .replaceChanged,
                                                    progress: { _ in })
        XCTAssertEqual(report.importedIDs.sorted(), ["100", "300"])
        XCTAssertEqual(report.replacedIDs, ["100"], "a project the library lacked is added, not replaced")
        XCTAssertEqual(report.identical, ["200"])
        XCTAssertTrue(report.failures.isEmpty, "\(report.failures)")
        XCTAssertEqual(text(library.appendingPathComponent("100/movie.mp4")), "changed-content")
        XCTAssertEqual(text(library.appendingPathComponent("200/movie.mp4")), "video-content")
        XCTAssertEqual(names(in: library), ["100", "200", "300"])
    }

    func testReplaceChangedRepairsAnInstalledProjectThatCannotPlay() async throws {
        let source = try project("123456")
        _ = try await importOne(source)
        let movie = library.appendingPathComponent("123456/movie.mp4")
        try FileManager.default.removeItem(at: movie)
        let report = try await importOne(source, policy: .replaceChanged)
        XCTAssertEqual(report.replacedIDs, ["123456"], "\(report.failures)")
        XCTAssertEqual(text(movie), "video-content")
    }

    func testReplaceChangedNeverTouchesAFolderThatIsNotAnInstalledWallpaper() async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: library, withIntermediateDirectories: true)
        // Files of someone's own, in a folder that happens to carry the id.
        let notes = library.appendingPathComponent("100")
        try fm.createDirectory(at: notes, withIntermediateDirectories: false)
        try Data("my notes".utf8).write(to: notes.appendingPathComponent("notes.txt"))
        // A file where the folder should be.
        try Data("not a folder".utf8).write(to: library.appendingPathComponent("200"))
        // A link to a real wallpaper elsewhere: the link is not the wallpaper, and its target is not the library's.
        let target = try project("300")
        let elsewhere = root.appendingPathComponent("elsewhere")
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try fm.moveItem(at: target, to: elsewhere.appendingPathComponent("300"))
        try fm.createSymbolicLink(at: library.appendingPathComponent("300"), withDestinationURL: elsewhere.appendingPathComponent("300"))

        for id in ["100", "200", "300"] {
            let source = try project(id)
            try Data("changed-content".utf8).write(to: source.appendingPathComponent("movie.mp4"))
            let report = try await importOne(source, policy: .replaceChanged)
            XCTAssertEqual(report.failures.count, 1, id)
            XCTAssertTrue(report.replacedIDs.isEmpty, id)
            XCTAssertTrue(report.importedIDs.isEmpty, id)
            XCTAssertTrue(report.skipped.isEmpty, id)
        }
        XCTAssertEqual(names(in: notes), ["notes.txt"])
        XCTAssertEqual(text(notes.appendingPathComponent("notes.txt")), "my notes")
        XCTAssertEqual(text(library.appendingPathComponent("200")), "not a folder")
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: library.appendingPathComponent("300").path),
                       elsewhere.appendingPathComponent("300").path)
        XCTAssertEqual(text(elsewhere.appendingPathComponent("300/movie.mp4")), "video-content")
        XCTAssertEqual(names(in: library.deletingLastPathComponent()), ["Library"], "no staging copy is left behind")
    }

    func testReplaceChangedStillReportsAnIdenticalProjectThatIsNotAWallpaper() async throws {
        let source = try project("broken", file: "missing.mp4")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: library.appendingPathComponent("broken"))
        let report = try await importOne(source, policy: .replaceChanged)
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertTrue(report.skipped.isEmpty)
        XCTAssertTrue(report.identical.isEmpty)
        XCTAssertTrue(report.replacedIDs.isEmpty)
    }

    func testAFailedSwapKeepsTheInstalledProjectAndLeavesNothingBehind() async throws {
        let fm = FileManager.default
        let source = try project("123456")
        _ = try await importOne(source)
        try Data("changed-content".utf8).write(to: source.appendingPathComponent("movie.mp4"))
        let installed = library.appendingPathComponent("123456")
        // A locked folder cannot be exchanged, whatever the reason the system gives.
        try fm.setAttributes([.immutable: true], ofItemAtPath: installed.path)
        defer { try? fm.setAttributes([.immutable: false], ofItemAtPath: installed.path) }
        let report = try await importOne(source, policy: .replaceChanged)
        try fm.setAttributes([.immutable: false], ofItemAtPath: installed.path)

        XCTAssertEqual(report.failures.count, 1)
        XCTAssertTrue(report.replacedIDs.isEmpty)
        XCTAssertTrue(report.importedIDs.isEmpty)
        XCTAssertEqual(text(installed.appendingPathComponent("movie.mp4")), "video-content")
        XCTAssertEqual(names(in: installed), ["movie.mp4", "project.json"])
        XCTAssertEqual(names(in: library.deletingLastPathComponent()), ["Library"], "the new copy is not left in staging")
    }

    func testCancellingAReplacementLeavesTheInstalledProject() async throws {
        let source = try largeProject("slow")
        _ = try await importOne(source)
        let movie = source.appendingPathComponent("movie.mp4")
        var changed = try Data(contentsOf: movie)
        changed[changed.count - 1] ^= 0xFF
        try changed.write(to: movie)
        let installed = library.appendingPathComponent("slow/movie.mp4")
        let original = try Data(contentsOf: installed)
        let task = Task {
            try await importer.importItems([source], into: library, duplicates: .replaceChanged, progress: { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            })
        }
        let report = try await task.value
        XCTAssertTrue(report.cancelled)
        XCTAssertTrue(report.replacedIDs.isEmpty)
        XCTAssertTrue(report.importedIDs.isEmpty)
        XCTAssertEqual(try Data(contentsOf: installed), original)
        XCTAssertEqual(names(in: library), ["slow"])
        XCTAssertEqual(names(in: library.deletingLastPathComponent()), ["Library"])
    }

    func testReplaceChangedAlsoReplacesAProjectMadeFromASingleFile() async throws {
        let video = root.appendingPathComponent("My Video.mp4")
        try Data("video-content".utf8).write(to: video)
        _ = try await importOne(video)
        let same = try await importOne(video, policy: .replaceChanged)
        XCTAssertEqual(same.identical, ["My Video.mp4"])
        XCTAssertTrue(same.replacedIDs.isEmpty)

        try Data("another video".utf8).write(to: video)
        let report = try await importOne(video, policy: .replaceChanged)
        XCTAssertEqual(report.replacedIDs, ["local-My Video.mp4"], "\(report.failures)")
        XCTAssertEqual(names(in: library), ["local-My Video.mp4"])
        XCTAssertEqual(text(library.appendingPathComponent("local-My Video.mp4/My Video.mp4")), "another video")
    }

    func testThePanelsChoiceNamesThePolicyAndAnythingElseKeepsWhatIsInstalled() {
        typealias Policy = WallpaperImportService.DuplicatePolicy
        XCTAssertEqual(Policy(panelValue: "skip"), .skip)
        XCTAssertEqual(Policy(panelValue: "keepBoth"), .keepBoth)
        XCTAssertEqual(Policy(panelValue: "replaceChanged"), .replaceChanged)
        // A stale or damaged page can never select the one policy that overwrites.
        for value in [nil, "", "replace", "Replace if changed", "replaceChanged ", "REPLACECHANGED", 1, true, ["replaceChanged"]] as [Any?] {
            XCTAssertEqual(Policy(panelValue: value), .skip, "\(String(describing: value))")
        }
    }

    @MainActor
    private func finish(_ imports: LibraryImportStore) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while imports.isBusy && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        if imports.isBusy {
            await imports.shutdown()
            XCTFail("The import did not finish before the deadline")
        }
    }

    @MainActor
    func testDisplaysReloadOnlyTheProjectsAnImportReplacedAfterTheLibraryRescan() async throws {
        let changed = try project("100")
        let same = try project("200")
        _ = try await importer.importItems([changed, same], into: library, duplicates: .skip, progress: { _ in })
        try Data("changed-content".utf8).write(to: changed.appendingPathComponent("movie.mp4"))
        let fresh = try project("300")
        let imports = LibraryImportStore(library: library)
        var events: [String] = []
        imports.refreshLibrary = { events.append("rescan") }
        imports.reloadReplaced = { events.append("reload " + $0) }

        try imports.start([changed, same, fresh], duplicates: .replaceChanged)
        try await finish(imports)
        XCTAssertEqual(imports.report?.replacedIDs, ["100"])
        XCTAssertNil(imports.failure)
        XCTAssertEqual(events, ["rescan", "reload 100"], "reloading follows the rescan, and only for the replaced project")

        // Nothing is replaced under the other policies, so nothing is reloaded.
        try Data("changed again".utf8).write(to: changed.appendingPathComponent("movie.mp4"))
        events = []
        try imports.start([changed], duplicates: .skip)
        try await finish(imports)
        XCTAssertEqual(imports.report?.skipped, ["100"])
        XCTAssertEqual(events, ["rescan"])
        try imports.start([changed], duplicates: .keepBoth)
        try await finish(imports)
        XCTAssertEqual(imports.report?.importedIDs.count, 1)
        XCTAssertEqual(events, ["rescan", "rescan"])
    }

    /// A callback the test holds suspended until it opens the gate, which then stays open.
    @MainActor
    private final class Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var isOpen = false
        private(set) var isClosedOnSomeone = false

        func pass() async {
            guard !isOpen else { return }
            isClosedOnSomeone = true
            await withCheckedContinuation { continuation = $0 }
            isClosedOnSomeone = false
        }

        func open() {
            isOpen = true
            continuation?.resume()
            continuation = nil
        }
    }

    @MainActor
    private func eventually(_ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

    @MainActor
    func testAQuitDoesNotWaitForADisplayStillReloadingAndReloadsNoMore() async throws {
        let first = try project("100")
        let second = try project("200")
        _ = try await importer.importItems([first, second], into: library, duplicates: .skip, progress: { _ in })
        for source in [first, second] { try Data("changed-content".utf8).write(to: source.appendingPathComponent("movie.mp4")) }
        let imports = LibraryImportStore(library: library)
        let gate = Gate()
        var reloaded: [String] = []
        imports.refreshLibrary = {}
        imports.reloadReplaced = { id in
            reloaded.append(id)
            await gate.pass()
        }
        try imports.start([first, second], duplicates: .replaceChanged)
        let reloading = try await eventually { gate.isClosedOnSomeone }
        XCTAssertTrue(reloading, "the import never reached the reload")

        var returned = false
        let quit = Task { @MainActor in
            await imports.shutdown()
            returned = true
        }
        let didNotWait = try await eventually { returned }
        // Opened either way, so a shutdown that does wait cannot outlive the test.
        gate.open()
        await quit.value
        XCTAssertTrue(didNotWait, "shutdown waited for a scene to finish loading, which would spend the quit's whole budget")

        try await finish(imports)
        XCTAssertEqual(reloaded.count, 1, "no further display is reloaded once the quit has begun: \(reloaded)")
        XCTAssertNil(imports.failure)
    }

    @MainActor
    func testAQuitDuringTheRescanDoesNotWaitForItOrReloadAfterIt() async throws {
        let changed = try project("100")
        _ = try await importer.importItems([changed], into: library, duplicates: .skip, progress: { _ in })
        try Data("changed-content".utf8).write(to: changed.appendingPathComponent("movie.mp4"))
        let imports = LibraryImportStore(library: library)
        let gate = Gate()
        var reloads = 0
        imports.refreshLibrary = { await gate.pass() }
        imports.reloadReplaced = { _ in reloads += 1 }
        try imports.start([changed], duplicates: .replaceChanged)
        let rescanning = try await eventually { gate.isClosedOnSomeone }
        XCTAssertTrue(rescanning, "the import never reached the rescan")

        var returned = false
        let quit = Task { @MainActor in
            await imports.shutdown()
            returned = true
        }
        let didNotWait = try await eventually { returned }
        gate.open()
        await quit.value
        XCTAssertTrue(didNotWait, "shutdown waited for the rescan")

        try await finish(imports)
        XCTAssertEqual(reloads, 0, "the app is exiting, so nothing is reloaded after the quit began")
    }

    @MainActor
    func testAQuitDuringTheImportStartsNeitherARescanNorAReload() async throws {
        let source = try project("100")
        let imports = LibraryImportStore(library: library)
        var events: [String] = []
        imports.refreshLibrary = { events.append("rescan") }
        imports.reloadReplaced = { events.append("reload " + $0) }
        try imports.start([source], duplicates: .skip)
        await imports.shutdown()
        XCTAssertFalse(imports.isBusy)
        XCTAssertTrue(imports.report?.cancelled == true)
        XCTAssertEqual(events, [])
    }
}
