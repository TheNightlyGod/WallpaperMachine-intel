import XCTest
@testable import WallpaperMachine

/// What the renderer's load journal is told about the running build. It releases every
/// held wallpaper when the stamp changes, so an update, or a rebuild that only bumps the
/// build number, has to produce a different one.
final class ClientPathsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("client-paths-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func bundle(version: String?, build: String?) throws -> Bundle {
        let bundleURL = root.appendingPathComponent("\(UUID().uuidString).bundle", isDirectory: true)
        let contents = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var info: [String: Any] = ["CFBundleIdentifier": "test.client-paths"]
        if let version { info["CFBundleShortVersionString"] = version }
        if let build { info["CFBundleVersion"] = build }
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return try XCTUnwrap(Bundle(url: bundleURL))
    }

    func testTheStampChangesWithTheVersionAndWithTheBuildNumber() throws {
        let release = ClientPaths.buildStamp(bundle: try bundle(version: "1.4.0", build: "88"))
        let rebuilt = ClientPaths.buildStamp(bundle: try bundle(version: "1.4.0", build: "89"))
        let updated = ClientPaths.buildStamp(bundle: try bundle(version: "1.4.1", build: "88"))

        XCTAssertEqual(Set([release, rebuilt, updated]).count, 3)
        XCTAssertEqual(release, ClientPaths.buildStamp(bundle: try bundle(version: "1.4.0", build: "88")))
    }

    func testABundleWithoutVersionNumbersStillNamesABuild() throws {
        let stamp = ClientPaths.buildStamp(bundle: try bundle(version: nil, build: nil))

        XCTAssertFalse(stamp.isEmpty, "an empty stamp would fall back to the crate version, which never changes")
    }
}
