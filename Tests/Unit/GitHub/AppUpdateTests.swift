import CryptoKit
import Security
import XCTest
@testable import WallpaperMachine

@MainActor
final class AppUpdateTests: XCTestCase {
    func testSemanticVersionRejectsInvalidAndOrdersStableReleases() {
        XCTAssertNil(SemanticVersion(""))
        XCTAssertNil(SemanticVersion("1.2"))
        XCTAssertNil(SemanticVersion("v1.2.3-beta"))
        XCTAssertNil(SemanticVersion("01.2.3"))
        XCTAssertEqual(SemanticVersion("v1.2.3")?.display, "1.2.3")
        XCTAssertLessThan(SemanticVersion("0.1.0")!, SemanticVersion("0.1.1")!)
        XCTAssertLessThan(SemanticVersion("0.9.9")!, SemanticVersion("1.0.0")!)
        XCTAssertEqual(SemanticVersion("V2.0.0"), SemanticVersion("2.0.0"))
    }

    func testParserReadsStableReleaseAndPrefersTheArm64DiskImage() throws {
        let release = try GitHubReleaseParser.decode(Self.releaseJSON(
            tag: "v1.2.3",
            assets: [
                ("latest-mac.yml", "https://github.com/bobbyhuang-dev/WallpaperMachine/releases/download/v1.2.3/latest-mac.yml", 100, nil),
                ("WallpaperMachine-1.2.3-arm64.zip", "https://github.com/bobbyhuang-dev/WallpaperMachine/releases/download/v1.2.3/WallpaperMachine-1.2.3-arm64.zip", 150, nil),
                ("WallpaperMachine-1.2.3.dmg", "https://github.com/bobbyhuang-dev/WallpaperMachine/releases/download/v1.2.3/WallpaperMachine-1.2.3.dmg", 200, nil),
                ("WallpaperMachine-1.2.3-arm64.dmg.sha256", "https://github.com/bobbyhuang-dev/WallpaperMachine/releases/download/v1.2.3/WallpaperMachine-1.2.3-arm64.dmg.sha256", 90, nil),
                ("WallpaperMachine-1.2.3-arm64.dmg", "https://github.com/bobbyhuang-dev/WallpaperMachine/releases/download/v1.2.3/WallpaperMachine-1.2.3-arm64.dmg", 300, "sha256:" + String(repeating: "ab", count: 32))
            ]
        ))
        XCTAssertEqual(release.version.display, "1.2.3")
        XCTAssertEqual(GitHubReleaseParser.selectAsset(from: release)?.name, "WallpaperMachine-1.2.3-arm64.dmg")
        XCTAssertEqual(GitHubReleaseParser.selectAsset(from: release)?.digest, "sha256:" + String(repeating: "ab", count: 32))
    }

    func testParserFallsBackToAnArm64DiskImageThenAnyProductDiskImage() throws {
        let renamed = try GitHubReleaseParser.decode(Self.releaseJSON(
            tag: "v1.2.3",
            assets: [
                ("WallpaperMachine-1.2.3.dmg", "https://github.com/bobbyhuang-dev/WallpaperMachine/releases/download/v1.2.3/plain.dmg", 200, nil),
                ("WallpaperMachine-arm64.dmg", "https://github.com/bobbyhuang-dev/WallpaperMachine/releases/download/v1.2.3/arm64.dmg", 300, nil)
            ]
        ))
        XCTAssertEqual(GitHubReleaseParser.selectAsset(from: renamed)?.name, "WallpaperMachine-arm64.dmg")

        let plain = try GitHubReleaseParser.decode(Self.releaseJSON(
            tag: "v1.2.3",
            assets: [
                ("Other-1.2.3-arm64.dmg", "https://github.com/bobbyhuang-dev/WallpaperMachine/releases/download/v1.2.3/other.dmg", 100, nil),
                ("WallpaperMachine-1.2.3.dmg", "https://github.com/bobbyhuang-dev/WallpaperMachine/releases/download/v1.2.3/plain.dmg", 200, nil)
            ]
        ))
        XCTAssertEqual(GitHubReleaseParser.selectAsset(from: plain)?.name, "WallpaperMachine-1.2.3.dmg")
    }

    func testZipOnlyReleaseIsLeftToAManualDownload() throws {
        let release = try GitHubReleaseParser.decode(Self.releaseJSON(
            tag: "v1.2.3",
            assets: [("WallpaperMachine-1.2.3-arm64.zip", "https://github.com/bobbyhuang-dev/WallpaperMachine/releases/download/v1.2.3/WallpaperMachine-1.2.3-arm64.zip", 300, nil)]
        ))
        XCTAssertNil(GitHubReleaseParser.selectAsset(from: release))
    }

    func testParserRejectsPrereleaseAndMissingVersion() {
        XCTAssertThrowsError(try GitHubReleaseParser.decode(Self.releaseJSON(tag: "v1.2.3", prerelease: true)))
        XCTAssertThrowsError(try GitHubReleaseParser.decode(Data("<html>rate limited</html>".utf8)))
        XCTAssertThrowsError(try GitHubReleaseParser.decode(Self.releaseJSON(tag: "nightly")))
    }

    func testMissingAppArchiveBecomesManualFallback() throws {
        let release = try GitHubReleaseParser.decode(Self.releaseJSON(
            tag: "v1.2.3",
            assets: [("notes.txt", "https://github.com/bobbyhuang-dev/WallpaperMachine/releases/download/v1.2.3/notes.txt", 12, nil)]
        ))
        XCTAssertNil(GitHubReleaseParser.selectAsset(from: release))
    }

    func testPublishedArchiveNameIsTheOneTheBuildUploads() {
        // scripts/package.py writes this name and .github/workflows/build.yml refuses
        // to publish anything else. Renaming one side without the others silently
        // drops every user back to a manual download.
        XCTAssertEqual(AppUpdateConfiguration.assetName(for: SemanticVersion("1.2.3")!),
                       "WallpaperMachine-1.2.3-arm64.dmg")
    }

    func testParserPrefersTheArchiveNamedForThisVersion() throws {
        let release = try GitHubReleaseParser.decode(Self.releaseJSON(
            tag: "v1.2.3",
            assets: [
                ("WallpaperMachine-1.2.2-arm64.dmg", "https://github.com/bobbyhuang-dev/WallpaperMachine/releases/download/v1.2.3/old.dmg", 100, nil),
                ("WallpaperMachine-1.2.3-arm64.dmg", "https://github.com/bobbyhuang-dev/WallpaperMachine/releases/download/v1.2.3/new.dmg", 300, nil)
            ]
        ))
        XCTAssertEqual(GitHubReleaseParser.selectAsset(from: release)?.name, "WallpaperMachine-1.2.3-arm64.dmg")
    }

    func testChecksumSidecarIsNeverDownloadedAsAnUpdate() throws {
        let release = try GitHubReleaseParser.decode(Self.releaseJSON(
            tag: "v1.2.3",
            assets: [("WallpaperMachine-1.2.3-arm64.dmg.sha256", "https://github.com/bobbyhuang-dev/WallpaperMachine/releases/download/v1.2.3/sum", 90, nil)]
        ))
        XCTAssertNil(GitHubReleaseParser.selectAsset(from: release))
    }

    func testDownloadedImageStaysInTheUpdatesFolderWhateverTheAssetName() {
        let archiveURL = AppUpdateWorkspace.live.archiveURL
        let folder = archiveURL("1.2.3", "WallpaperMachine-1.2.3-arm64.dmg").deletingLastPathComponent()
        XCTAssertEqual(folder.lastPathComponent, "Updates")
        for (name, expected) in [("../../x/WallpaperMachine.dmg", "WallpaperMachine.dmg"), ("..", "WallpaperMachine-1.2.3.dmg"),
                                 ("", "WallpaperMachine-1.2.3.dmg"), ("/", "WallpaperMachine-1.2.3.dmg")] {
            let url = archiveURL("1.2.3", name)
            XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, folder.standardizedFileURL, name)
            XCTAssertEqual(url.lastPathComponent, expected, name)
        }
    }

    func testDiscardingArchivesEmptiesTheUpdatesFolderButTheKeptImage() throws {
        let fileManager = FileManager.default
        let folder = fileManager.temporaryDirectory.appendingPathComponent("mwe-update-discard-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: folder) }
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let names = ["WallpaperMachine-1.6.0-arm64.dmg", "WallpaperMachine-1.7.0-arm64.dmg",
                     "WallpaperMachine-1.8.0-arm64.dmg"]
        for name in names { try Data("image".utf8).write(to: folder.appendingPathComponent(name)) }
        let kept = folder.appendingPathComponent(names[2])

        AppUpdateWorkspace.discardArchives(in: folder, keeping: kept)
        XCTAssertEqual(try fileManager.contentsOfDirectory(atPath: folder.path), [names[2]])

        AppUpdateWorkspace.discardArchives(in: folder, keeping: nil)
        XCTAssertEqual(try fileManager.contentsOfDirectory(atPath: folder.path), [])

        // No folder yet (nothing ever downloaded) is not an error.
        AppUpdateWorkspace.discardArchives(in: folder.appendingPathComponent("missing"), keeping: nil)
    }

    func testReleaseNotesReadTheSectionsAndStopAtTheInstallFooter() throws {
        let body = """
        ![WallpaperMachine 1.2.3](https://raw.githubusercontent.com/o/r/v1.2.3/Resources/ReleaseBanners/1.2.3.jpg)

        ### New

        - **panel** — Add a filter rail ([`aaa1111`](https://github.com/o/r/commit/aaa1111))

        ### Fixed

        - **scene** — Stop a crash ([`bbb2222`](https://github.com/o/r/commit/bbb2222))

        Plus 3 documentation, test and tooling commits.

        **Full changelog**: https://github.com/o/r/compare/v1.2.2...v1.2.3

        \(ReleaseNotes.boundary)

        ### Install

        1. Open `WallpaperMachine-1.2.3-arm64.dmg` and drag WallpaperMachine to Applications.
        """
        let notes = try XCTUnwrap(ReleaseNotes(version: "1.2.3", body: body))
        XCTAssertEqual(notes.sections.map(\.title), ["New", "Fixed", ""])
        XCTAssertEqual(notes.sections[0].items, ["panel — Add a filter rail"])
        XCTAssertEqual(notes.sections[1].items, ["scene — Stop a crash"])
        XCTAssertEqual(notes.sections[2].items, ["Plus 3 documentation, test and tooling commits."])
    }

    func testReleaseNotesRecognizeTranslatedHighlightsWithoutHighlightingOtherSections() throws {
        for (highlights, fixed) in [("Highlights", "Fixed"), ("亮点", "修复"), ("주요 변경 사항", "수정됨")] {
            let notes = try XCTUnwrap(ReleaseNotes(version: "1.5.7", body: """
            #### \(highlights)
            - A highlighted change
            #### \(fixed)
            - An ordinary fix
            """))
            XCTAssertEqual(notes.sections.count, 2)
            XCTAssertEqual(notes.sections.map(\.isHighlights), [true, false])
            XCTAssertTrue(notes.sections.allSatisfy(\.isList))
        }
    }

    func testReleaseNotesDropIssueAndCommitReferencesFromThePlainReading() throws {
        let notes = try XCTUnwrap(ReleaseNotes(version: "1.6.2", body: """
        #### Bug Fixes

        - Names fit on narrow tiles (closes [#76](https://github.com/o/r/issues/76), closes [#77](https://github.com/o/r/issues/77)) ([bb75725](https://github.com/o/r/commit/bb75725aa))
        - Stop a crash ([aaa1111](https://github.com/o/r/commit/aaa1111), [bbb2222](https://github.com/o/r/commit/bbb2222))
        - Read the [guide](https://github.com/o/r/wiki) (see [notes](https://github.com/o/r/wiki/notes))
        """))
        XCTAssertEqual(notes.sections.first?.items, [
            "Names fit on narrow tiles", "Stop a crash", "Read the guide (see notes)",
        ])
        XCTAssertEqual(
            notes.sections.first?.markdown.first,
            "Names fit on narrow tiles (closes [#76](https://github.com/o/r/issues/76), closes [#77](https://github.com/o/r/issues/77)) ([bb75725](https://github.com/o/r/commit/bb75725aa))",
            "the update window keeps the links")
    }

    func testManifestCarriesTheChangelogForTheUpdateWindow() throws {
        let changelog = "## [1.2.3](https://github.com/o/r/compare/v1.2.2...v1.2.3) (2026-10-24)\n"
        let release = try GitHubReleaseParser.decode(Self.releaseJSON(tag: "v1.2.3", changelog: changelog))
        XCTAssertEqual(release.changelog, changelog)
        XCTAssertEqual(try GitHubReleaseParser.decode(Self.releaseJSON(tag: "v1.2.3")).changelog, "",
                       "the API and older manifests have none")
    }

    func testCheckListsEveryReleaseSinceTheRunningVersion() async {
        let fixture = Fixture()
        let changelog = ["1.1.0", "1.0.5", "1.0.0"].map { version in
            """
            ## [\(version)](https://github.com/o/r/compare/v0.9.0...v\(version)) (2026-10-24)
            ### English
            #### Features
            - Change in \(version)
            ### 简体中文
            #### 新功能
            - \(version) 的变更
            ### 한국어
            #### 새로운 기능
            - \(version) 변경

            """
        }.joined()
        fixture.client.release = fixture.release(version: "1.1.0", changelog: changelog)
        await fixture.store.checkForUpdates()
        XCTAssertEqual(fixture.store.pendingReleases.map(\.version.display), ["1.1.0", "1.0.5"])
        XCTAssertEqual(fixture.store.pendingReleases.first?.date, "2026-10-24")

        fixture.client.release = fixture.release(version: "1.0.0", changelog: changelog)
        await fixture.store.checkForUpdates()
        XCTAssertEqual(fixture.store.pendingReleases, [], "nothing to show once up to date")
    }

    func testSkipAndAutomaticInstallsAreRememberedAcrossLaunches() {
        let fixture = Fixture()
        XCTAssertFalse(fixture.store.automaticallyInstallsUpdates, "asks before installing by default")
        XCTAssertNil(fixture.store.skippedVersion)
        fixture.store.automaticallyInstallsUpdates = true
        fixture.store.skippedVersion = "1.1.0"
        let relaunched = AppUpdateStore(
            currentVersion: "1.0.0", client: FakeAppUpdateClient(), defaults: fixture.defaults)
        XCTAssertTrue(relaunched.automaticallyInstallsUpdates)
        XCTAssertEqual(relaunched.skippedVersion, "1.1.0")
    }

    func testAReleaseWithNothingToSayHasNoNotes() {
        XCTAssertNil(ReleaseNotes(version: "1.2.3", body: ""))
        XCTAssertNil(ReleaseNotes(version: "1.2.3",
                                  body: "**Full changelog**: https://github.com/o/r/compare/v1.2.2...v1.2.3"))
    }

    func testCheckPublishesWhatTheNewestReleaseChanged() async {
        let fixture = Fixture()
        fixture.client.release = fixture.release(version: "1.1.0", notes: "### Fixed\n\n- **scene** — Stop a crash\n")
        await fixture.store.checkForUpdates()
        XCTAssertEqual(fixture.store.releaseNotes?.version, "1.1.0")
        XCTAssertEqual(fixture.store.releaseNotes?.sections.first?.items, ["scene — Stop a crash"])
    }

    func testDownloadHostAllowlistAndDigestParsing() {
        XCTAssertTrue(GitHubReleaseDownload.isAllowed(URL(string: "https://github.com/bobbyhuang-dev/WallpaperMachine/releases/download/v1/app.dmg")!))
        XCTAssertTrue(GitHubReleaseDownload.isAllowed(URL(string: "https://objects.githubusercontent.com/github-production-release-asset/1")!))
        XCTAssertFalse(GitHubReleaseDownload.isAllowed(URL(string: "http://github.com/file")!))
        XCTAssertFalse(GitHubReleaseDownload.isAllowed(URL(string: "https://evil.example/file")!))
        let mirror = URL(string: "https://mirror.example/")!
        XCTAssertTrue(GitHubReleaseDownload.isAllowed(URL(string: "https://mirror.example/https://github.com/o/r/app.dmg")!, mirrors: [mirror]))
        XCTAssertFalse(GitHubReleaseDownload.isAllowed(URL(string: "https://mirror.example/https://github.com/o/r/app.dmg")!))
        XCTAssertEqual(AppUpdateRoutes.url(URL(string: "https://github.com/o/r/app.dmg")!, through: mirror).absoluteString,
                       "https://mirror.example/https://github.com/o/r/app.dmg")
        XCTAssertEqual(GitHubReleaseDownload.parseSHA256Hex("SHA256:" + String(repeating: "AA", count: 32)), String(repeating: "aa", count: 32))
        XCTAssertNil(GitHubReleaseDownload.parseSHA256Hex("sha256:deadbeef"))
    }

    /// A disk image is kept only when its SHA-256 matches the digest the manifest or GitHub gave;
    /// one that comes without a usable digest cannot be verified, so it is refused too.
    func testUpdateDownloadNeedsAMatchingSHA256Digest() async throws {
        let path = "/fixture/\(UUID().uuidString)/WallpaperMachine.dmg"
        let body = Data("disk image".utf8)
        UpdateHTTPProtocol.remove("github.com")
        UpdateHTTPProtocol.register("github.com", routes: [path: .init(status: 200, body: body)])
        defer { UpdateHTTPProtocol.remove("github.com") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateHTTPProtocol.self]
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mwe-update-digest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func download(digest: String?) async throws {
            try await GitHubReleaseDownload(
                sources: [URL(string: "https://github.com\(path)")!], destination: folder.appendingPathComponent(UUID().uuidString),
                expectedSize: Int64(body.count), digest: digest, configuration: configuration, progress: { _, _, _ in }
            ).start()
        }
        let hash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        try await download(digest: "sha256:" + hash)
        for digest in [nil, "sha512:" + hash, "sha256:" + String(repeating: "0", count: 64)] {
            do {
                try await download(digest: digest)
                XCTFail("\(digest ?? "no digest") must not pass")
            } catch let issue as AppUpdateIssue {
                XCTAssertEqual(issue.code, .verification, digest ?? "no digest")
            }
        }
        // Only the matching and the mismatching digests were worth fetching.
        XCTAssertEqual(UpdateHTTPProtocol.requests("github.com").count, 2)
    }

    /// A source that drops, crawls or ignores Range hands over to the next, which carries on
    /// from the bytes already written; the result is the release's image either way.
    func testDownloadMovesToTheNextSourceAndResumesWhereItStopped() async throws {
        let path = "/fixture/\(UUID().uuidString)/WallpaperMachine.dmg"
        let body = Data((0..<4_096).map { UInt8($0 % 251) })
        let digest = "sha256:" + SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        let direct = "release-assets.githubusercontent.com"
        let mirrorHost = "mirror-\(UUID().uuidString).invalid"
        let mirror = URL(string: "https://\(mirrorHost)/")!
        let source = URL(string: "https://\(direct)\(path)")!
        let mirrored = AppUpdateRoutes.url(source, through: mirror)
        defer { UpdateHTTPProtocol.remove(direct); UpdateHTTPProtocol.remove(mirrorHost) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateHTTPProtocol.self]
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mwe-update-resume-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        func download(direct directResponse: UpdateHTTPProtocol.Response, mirror mirrorResponse: UpdateHTTPProtocol.Response,
                      slowSourceRate: Int64 = GitHubReleaseDownload.slowSourceRate) async throws -> (URL, Data) {
            UpdateHTTPProtocol.remove(direct)
            UpdateHTTPProtocol.remove(mirrorHost)
            UpdateHTTPProtocol.register(direct, routes: [path: directResponse])
            UpdateHTTPProtocol.register(mirrorHost, routes: [mirrored.path: mirrorResponse])
            let destination = folder.appendingPathComponent(UUID().uuidString)
            let finished = try await GitHubReleaseDownload(
                sources: [source, mirrored], mirrors: [mirror], destination: destination, expectedSize: Int64(body.count),
                digest: digest, configuration: configuration, slowSourceGrace: .zero, slowSourceRate: slowSourceRate,
                progress: { _, _, _ in }
            ).start()
            return (finished, try Data(contentsOf: destination))
        }

        // GitHub's response ends early; the mirror sends only the rest.
        var (finished, data) = try await download(direct: .init(status: 200, body: body, endsAfter: 1_000),
                                                  mirror: .init(status: 200, body: body, honorsRange: true))
        XCTAssertEqual(finished, mirrored)
        XCTAssertEqual(data, body)
        XCTAssertEqual(UpdateHTTPProtocol.ranges(mirrorHost), ["bytes=1000-"])

        // A mirror that ignores Range sends the whole image, which replaces the partial one.
        (finished, data) = try await download(direct: .init(status: 200, body: body, endsAfter: 1_000),
                                              mirror: .init(status: 200, body: body))
        XCTAssertEqual(data, body)

        // A source too slow to finish soon gives way while another is left; the last one never does.
        (finished, data) = try await download(direct: .init(status: 200, body: body, chunks: 4),
                                              mirror: .init(status: 200, body: body, honorsRange: true, chunks: 4),
                                              slowSourceRate: .max / 2)
        XCTAssertEqual(finished, mirrored)
        XCTAssertEqual(data, body)
        XCTAssertEqual(UpdateHTTPProtocol.ranges(mirrorHost), ["bytes=1024-"])

        // Sources that add nothing end the download with the last one's failure.
        do {
            _ = try await download(direct: .init(status: 503, body: Data()), mirror: .init(status: 404, body: Data()))
            XCTFail("Two dead sources must not pass")
        } catch let issue as AppUpdateIssue {
            XCTAssertEqual(issue.code, .network)
        }

        // An image that doesn't match the digest is refused, wherever its bytes came from.
        do {
            var altered = body
            altered[10] ^= 0xFF
            _ = try await download(direct: .init(status: 200, body: altered), mirror: .init(status: 200, body: altered))
            XCTFail("An altered image must not pass")
        } catch let issue as AppUpdateIssue {
            XCTAssertEqual(issue.code, .verification)
        }
    }

    func testRepeatedTruncatedResponsesThatIgnoreRangeEventuallyFail() async throws {
        let host = "mirror-\(UUID().uuidString).invalid"
        let mirror = URL(string: "https://\(host)/")!
        let body = Data(repeating: 1, count: 4_096)
        let digest = "sha256:" + SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        UpdateHTTPProtocol.register(host, routes: [
            "/first": .init(status: 200, body: body, endsAfter: 1_000),
            "/second": .init(status: 200, body: body, endsAfter: 2_000)
        ])
        defer { UpdateHTTPProtocol.remove(host) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateHTTPProtocol.self]
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("mwe-truncated-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: destination) }
        let download = Task {
            try await GitHubReleaseDownload(
                sources: [mirror.appendingPathComponent("first"), mirror.appendingPathComponent("second")],
                mirrors: [mirror], destination: destination, expectedSize: Int64(body.count),
                digest: digest, configuration: configuration, progress: { _, _, _ in }
            ).start()
        }
        let deadline = Task {
            try await Task.sleep(for: .seconds(2))
            download.cancel()
        }
        defer { deadline.cancel() }
        do {
            _ = try await download.value
            XCTFail("Truncated sources must fail")
        } catch let issue as AppUpdateIssue {
            XCTAssertEqual(issue.code, .network)
        } catch {
            XCTFail("The download must terminate itself, not wait for cancellation: \(error)")
        }
        XCTAssertLessThanOrEqual(UpdateHTTPProtocol.requests(host).count, 4)
    }

    func testInstallableLocationsAreApplicationsFolders() {
        XCTAssertTrue(AppUpdateInstaller.isInstallableLocation(URL(fileURLWithPath: "/Applications/WallpaperMachine.app")))
        XCTAssertTrue(AppUpdateInstaller.isInstallableLocation(
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/WallpaperMachine.app")))
        XCTAssertFalse(AppUpdateInstaller.isInstallableLocation(URL(fileURLWithPath: "/tmp/WallpaperMachine.app")))
    }

    func testInstallerAcceptsOnlyThisAppsBundle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mwe-update-validate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("WallpaperMachine.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "app.wallpapermachine"], format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        try Data("binary".utf8).write(to: app.appendingPathComponent("Contents/MacOS/WallpaperMachine"))
        XCTAssertEqual(try AppUpdateInstaller.findApplication(in: root).path, app.path)
        try AppUpdateInstaller.validate(app)

        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.other"], format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        XCTAssertThrowsError(try AppUpdateInstaller.validate(app))
    }

    func testInstallerCopiesTheAppOutOfTheDiskImageAndDetachesIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mwe-update-dmg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let image = try Self.makeDiskImage(in: root, bundleIdentifier: "app.wallpapermachine")
        defer { Self.forceDetach(image) }

        let app = try await AppUpdateInstaller(signingRequirement: Self.adHocRequirement, currentVersion: "1.0.0").prepareInstallation(archive: image)
        let work = app.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: work) }
        XCTAssertEqual(app.lastPathComponent, "WallpaperMachine.app")
        XCTAssertFalse(app.path.hasPrefix(work.appendingPathComponent("mount").path + "/"))
        XCTAssertFalse(app.path.hasPrefix("/Volumes/"))
        XCTAssertNoThrow(try AppUpdateInstaller.validate(app))
        XCTAssertEqual(try Self.attachedDevices(of: image), [])
    }

    func testManualUpdateExposesOnlyTheVerifiedAppFromARepackagedImage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mwe-repackaged-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let image = try Self.makeDiskImage(in: root, bundleIdentifier: "app.wallpapermachine", withUnsignedSibling: true)
        defer { Self.forceDetach(image) }
        let installer = AppUpdateInstaller(currentAppURL: root.appendingPathComponent("Running.app"),
                                          signingRequirement: Self.adHocRequirement, currentVersion: "1.0.0")
        let fixture = Fixture(installer: installer)
        fixture.client.sourceArchive = image
        fixture.client.release = fixture.release(version: "1.2.3")
        defer {
            try? FileManager.default.removeItem(at: fixture.destination)
            for app in fixture.revealed where app.lastPathComponent == "WallpaperMachine.app" {
                try? FileManager.default.removeItem(at: app.deletingLastPathComponent())
            }
        }
        await fixture.store.checkForUpdates()
        await expect(fixture.store.downloadUpdate(), equals: .ready(currentVersion: "1.0.0", availableVersion: "1.2.3"))
        XCTAssertTrue(fixture.opened.isEmpty, "The untrusted DMG must never be opened")
        fixture.store.revealDownloadedUpdate()
        let app = try XCTUnwrap(fixture.revealed.first)
        XCTAssertEqual(fixture.revealed, [app, app])
        XCTAssertEqual(app.lastPathComponent, "WallpaperMachine.app")
        XCTAssertNotEqual(app, fixture.destination)
        try AppUpdateInstaller.verifySignature(of: app, requirement: Self.adHocRequirement)
        try AppUpdateInstaller.verifyNewer(app, than: "1.0.0")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: app.deletingLastPathComponent().appendingPathComponent("Install Update.app").path))
        XCTAssertEqual(try Self.attachedDevices(of: image), [])
    }

    func testInstallerRejectsAForeignAppInTheDiskImageAndDetachesIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mwe-update-dmg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let image = try Self.makeDiskImage(in: root, bundleIdentifier: "com.example.other")
        defer { Self.forceDetach(image) }

        do {
            _ = try await AppUpdateInstaller(signingRequirement: Self.adHocRequirement, currentVersion: "1.0.0").prepareInstallation(archive: image)
            XCTFail("Foreign applications must not be accepted")
        } catch {
            XCTAssertEqual((error as? AppUpdateIssue)?.code, .verification)
        }
        XCTAssertEqual(try Self.attachedDevices(of: image), [])
    }

    func testInstallerRejectsACopyNotSignedWithTheReleaseCertificateAndDetachesIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mwe-update-dmg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let image = try Self.makeDiskImage(in: root, bundleIdentifier: "app.wallpapermachine")
        defer { Self.forceDetach(image) }

        do {
            _ = try await AppUpdateInstaller(currentVersion: "1.0.0").prepareInstallation(archive: image)
            XCTFail("A copy signed without the release certificate must not be accepted")
        } catch {
            XCTAssertEqual((error as? AppUpdateIssue)?.code, .verification)
        }
        XCTAssertEqual(try Self.attachedDevices(of: image), [])
    }

    /// A genuine older release passes the signature check, so a copy must also be newer than
    /// the running one: a mirror relaying an old release as the latest can't roll the app back.
    func testInstallerRefusesACopyThatIsNotNewer() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mwe-update-version-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try Self.makeApplication(in: root, bundleIdentifier: "app.wallpapermachine", version: "1.2.3", signed: false)
        XCTAssertNoThrow(try AppUpdateInstaller.verifyNewer(app, than: "1.2.2"))
        for current in ["1.2.3", "2.0.0", ""] {
            XCTAssertThrowsError(try AppUpdateInstaller.verifyNewer(app, than: current), current)
        }
    }

    /// A requirement Security cannot compile refuses every copy, so a typo in it would stop
    /// all in-app updates while the refusal tests below still pass.
    func testSignedApplicationMustMatchOfferedVersionAndSystemRequirement() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("update-target-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try Self.makeApplication(in: root, bundleIdentifier: AppUpdateConfiguration.bundleIdentifier)
        func release(_ version: String, minimum: String? = nil) -> GitHubRelease {
            GitHubRelease(version: SemanticVersion(version)!, htmlURL: AppUpdateConfiguration.releasesURL,
                          prerelease: false, assets: [], minimumSystemVersion: minimum)
        }
        XCTAssertNoThrow(try AppUpdateInstaller.verifyTarget(app, release: release("1.2.3"), systemVersion: "15"))
        XCTAssertThrowsError(try AppUpdateInstaller.verifyTarget(app, release: release("1.2.4"), systemVersion: "15"))
        XCTAssertThrowsError(try AppUpdateInstaller.verifyTarget(app, release: release("1.2.3"), systemVersion: "14"))
        XCTAssertThrowsError(try AppUpdateInstaller.verifyTarget(app, release: release("1.2.3", minimum: "16"), systemVersion: "16"))
    }

    func testReleaseSigningRequirementCompiles() {
        var requirement: SecRequirement?
        XCTAssertEqual(SecRequirementCreateWithString(
            AppUpdateConfiguration.signingRequirement as CFString, [], &requirement), errSecSuccess)
        XCTAssertNotNil(requirement)
    }

    func testSignatureCheckRefusesAnUnsignedOrAlteredCopy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mwe-update-sign-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try Self.makeApplication(in: root, bundleIdentifier: "app.wallpapermachine", signed: false)
        XCTAssertThrowsError(try AppUpdateInstaller.verifySignature(of: app, requirement: Self.adHocRequirement))

        try Self.signAdHoc(app)
        XCTAssertNoThrow(try AppUpdateInstaller.verifySignature(of: app, requirement: Self.adHocRequirement))
        XCTAssertThrowsError(try AppUpdateInstaller.verifySignature(
            of: app, requirement: AppUpdateConfiguration.signingRequirement))

        let info = app.appendingPathComponent("Contents/Info.plist")
        var values = try XCTUnwrap(NSDictionary(contentsOf: info) as? [String: Any])
        values["CFBundleShortVersionString"] = "9.9.9"
        try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0).write(to: info)
        XCTAssertThrowsError(try AppUpdateInstaller.verifySignature(of: app, requirement: Self.adHocRequirement))
    }

    func testOnlyACopyThisUserCanWriteIsReplacedInPlace() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mwe-update-perm-\(UUID().uuidString)")
        let app = root.appendingPathComponent("WallpaperMachine.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        XCTAssertTrue(AppUpdateInstaller.canReplace(app))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        XCTAssertFalse(AppUpdateInstaller.canReplace(app))
    }

    func testReplacementSwapsInTheNewAppAndReopensIt() throws {
        let fixture = try ReplacementFixture()
        defer { fixture.remove() }
        try fixture.makeApp(at: fixture.destination, marker: "old")
        try fixture.makeApp(at: fixture.source, marker: "new")

        try fixture.run()
        XCTAssertEqual(try fixture.marker(), "new")
        XCTAssertEqual(try fixture.leftovers(), [])
        XCTAssertEqual(try fixture.reopened(), [fixture.destination.path])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.source.deletingLastPathComponent().path))
    }

    func testFailedReplacementKeepsAndReopensThePreviousApp() throws {
        let fixture = try ReplacementFixture()
        defer { fixture.remove() }
        try fixture.makeApp(at: fixture.destination, marker: "old")
        // No extracted copy: the copy step fails after the app has already quit.

        try fixture.run()
        XCTAssertEqual(try fixture.marker(), "old")
        XCTAssertEqual(try fixture.leftovers(), [])
        XCTAssertEqual(try fixture.reopened(), [fixture.destination.path])
    }

    func testCheckFindsUpdateWithoutDownloading() async {
        let fixture = Fixture()
        fixture.client.release = fixture.release(version: "1.1.0")
        await expect(fixture.store.checkForUpdates(), equals: .available(currentVersion: "1.0.0", availableVersion: "1.1.0"))
        XCTAssertEqual(fixture.client.downloadCalls, 0)
    }

    func testCheckReportsUpToDateAndManualRelease() async {
        let current = Fixture()
        current.client.release = current.release(version: "1.0.0")
        await expect(current.store.checkForUpdates(), equals: .upToDate(currentVersion: "1.0.0"))
        current.client.release = current.release(version: "0.9.0")
        await expect(current.store.checkForUpdates(), equals: .upToDate(currentVersion: "1.0.0"))

        let notes = Fixture()
        notes.client.release = notes.release(version: "1.2.0", assets: [])
        await expect(notes.store.checkForUpdates(), equals: .manual(currentVersion: "1.0.0", availableVersion: "1.2.0"))
        await expect(notes.store.downloadUpdate(), equals: .error(currentVersion: "1.0.0", operation: .download, code: .configuration, availableVersion: "1.2.0"))
        XCTAssertEqual(notes.client.downloadCalls, 0)
    }

    func testMissingLatestReleaseIsNormalAndDoesNotKeepAnOldUpdate() async {
        let http = UpdateHTTPFixture()
        let store = AppUpdateStore(currentVersion: "1.0.0", client: http.client)
        http.respond(latest: .init(status: 200, body: Self.releaseJSON(
            tag: "v1.1.0", body: "### Fixed\n\n- A fixture update",
            assets: [("WallpaperMachine-1.1.0-arm64.dmg", "https://github.com/o/r/update.dmg", 100, nil)])))
        await expect(store.checkForUpdates(), equals: .available(currentVersion: "1.0.0", availableVersion: "1.1.0"))
        XCTAssertNotNil(store.releaseNotes)

        http.respond(latest: .init(status: 404, body: Data()))
        let empty = await store.checkForUpdates()
        let card = UpdatePresentation(state: empty)
        XCTAssertEqual(card.status, .noRelease)
        XCTAssertEqual(card.action, .checkForUpdates)
        XCTAssertFalse(card.showsReleases)
        XCTAssertNil(empty.availableVersion)
        XCTAssertNil(store.releaseNotes)
        XCTAssertFalse(empty.isBusy)

        http.respond(latest: .init(status: 200, body: Self.releaseJSON(tag: "v1.2.0")))
        await expect(store.checkForUpdates(), equals: .manual(currentVersion: "1.0.0", availableVersion: "1.2.0"))
    }

    func testMissingRepositoryIsNotReportedAsNoUpdate() async {
        let http = UpdateHTTPFixture()
        http.respond(latest: .init(status: 404, body: Data()), repository: .init(status: 404, body: Data()))
        let store = AppUpdateStore(currentVersion: "1.0.0", client: http.client)
        await expect(store.checkForUpdates(), equals: .error(currentVersion: "1.0.0", operation: .check, code: .configuration, availableVersion: nil))
    }

    func testRepositoryLookupFailureRemainsANetworkError() async {
        let http = UpdateHTTPFixture()
        http.respond(latest: .init(status: 404, body: Data()), repository: .init(status: 0, body: Data(), error: .timedOut))
        let store = AppUpdateStore(currentVersion: "1.0.0", client: http.client)
        await expect(store.checkForUpdates(), equals: .error(currentVersion: "1.0.0", operation: .check, code: .network, availableVersion: nil))
    }

    func testMalformedRepositoryMetadataIsNotReportedAsNoUpdate() async {
        let http = UpdateHTTPFixture()
        http.respond(latest: .init(status: 404, body: Data()), repository: .init(status: 200, body: Data(#"{"message":"unexpected response"}"#.utf8)))
        let store = AppUpdateStore(currentVersion: "1.0.0", client: http.client)
        await expect(store.checkForUpdates(), equals: .error(currentVersion: "1.0.0", operation: .check, code: .configuration, availableVersion: nil))
    }

    func testExhaustedAnonymousRateLimitIsReportedWithItsResetTime() async {
        let reset = Date(timeIntervalSince1970: 1_900_000_000)
        let http = UpdateHTTPFixture()
        http.respond(latest: .init(status: 403, body: Data(#"{"message":"API rate limit exceeded"}"#.utf8),
                                   headers: ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "1900000000"]))
        var clock = reset.addingTimeInterval(-600)
        let store = AppUpdateStore(currentVersion: "1.0.0", client: http.client, now: { clock })
        await expect(store.checkForUpdates(), equals: .error(currentVersion: "1.0.0", operation: .check, code: .rateLimited, availableVersion: nil))
        XCTAssertEqual(store.rateLimitedUntil, reset)
        let card = UpdatePresentation(state: store.state, rateLimitedUntil: store.rateLimitedUntil)
        XCTAssertEqual(card.statusText, UpdatePresentation.errorText(.rateLimited, rateLimitedUntil: reset))
        XCTAssertNotEqual(card.statusText, UpdatePresentation.errorText(.network))

        // A plain 403 (no limit headers) is still an ordinary failure.
        http.respond(latest: .init(status: 403, body: Data()))
        clock = reset.addingTimeInterval(1)
        await expect(store.checkForUpdates(), equals: .error(currentVersion: "1.0.0", operation: .check, code: .network, availableVersion: nil))
        XCTAssertNil(store.rateLimitedUntil)
    }

    func testSecondaryRateLimitUsesRetryAfter() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let url = URL(string: "https://api.github.com/repos/o/r/releases/latest")!
        let secondary = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil, headerFields: ["retry-after": "90"]))
        XCTAssertEqual(GitHubReleaseClient.rateLimitIssue(secondary, now: now)?.retryAfter, now.addingTimeInterval(90))
        let forbidden = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: ["x-ratelimit-remaining": "12"]))
        XCTAssertNil(GitHubReleaseClient.rateLimitIssue(forbidden, now: now))
    }

    func testChecksWaitOutTheRateLimitWithoutSpendingRequests() async {
        let reset = Date(timeIntervalSince1970: 1_900_000_000)
        var clock = reset.addingTimeInterval(-600)
        let client = FakeAppUpdateClient()
        client.fetchError = AppUpdateIssue(code: .rateLimited, detail: "", retryAfter: reset)
        let store = AppUpdateStore(currentVersion: "1.0.0", client: client, now: { clock })
        _ = await store.checkForUpdates()
        _ = await store.checkInBackground()
        await expect(store.checkForUpdates(), equals: .error(currentVersion: "1.0.0", operation: .check, code: .rateLimited, availableVersion: nil))
        XCTAssertEqual(client.fetchCalls, 1)

        client.fetchError = nil
        client.release = nil
        clock = reset
        await expect(store.checkForUpdates(), equals: .noRelease(currentVersion: "1.0.0"))
        XCTAssertEqual(client.fetchCalls, 2)
        XCTAssertNil(store.rateLimitedUntil)
    }

    func testManifestAnswersTheCheckWithoutSpendingAnAPIRequest() async {
        let http = UpdateHTTPFixture()
        let digest = "sha256:" + String(repeating: "cd", count: 32)
        http.respond(latest: .init(status: 500, body: Data()),
                     manifest: .init(status: 200, body: Self.releaseJSON(
                        tag: "v1.1.0", body: "### Fixed\n\n- From the manifest",
                        assets: [("WallpaperMachine-1.1.0-arm64.dmg", "https://github.com/o/r/releases/download/v1.1.0/WallpaperMachine-1.1.0-arm64.dmg", 4_096, digest)])))
        let store = AppUpdateStore(currentVersion: "1.0.0", client: http.client)
        await expect(store.checkForUpdates(), equals: .available(currentVersion: "1.0.0", availableVersion: "1.1.0"))
        XCTAssertEqual(store.releaseNotes?.sections.first?.items, ["From the manifest"])
        XCTAssertEqual(http.requests, [UpdateHTTPFixture.manifestPath])
    }

    func testReleaseWithoutAManifestIsReadFromTheAPI() async {
        let http = UpdateHTTPFixture()
        http.respond(latest: .init(status: 200, body: Self.releaseJSON(
            tag: "v1.1.0", assets: [("WallpaperMachine-1.1.0-arm64.dmg", "https://github.com/o/r/update.dmg", 100, nil)])))
        let store = AppUpdateStore(currentVersion: "1.0.0", client: http.client)
        await expect(store.checkForUpdates(), equals: .available(currentVersion: "1.0.0", availableVersion: "1.1.0"))
        XCTAssertEqual(http.requests, [UpdateHTTPFixture.manifestPath, UpdateHTTPFixture.latestPath])

        // An unreadable manifest is not a dead end either.
        http.respond(latest: .init(status: 200, body: Self.releaseJSON(tag: "v1.2.0")),
                     manifest: .init(status: 200, body: Data("<html>not a manifest</html>".utf8)))
        await expect(store.checkForUpdates(), equals: .manual(currentVersion: "1.0.0", availableVersion: "1.2.0"))
    }

    func testManifestFailuresAreReportedWithoutFallingBackToTheAPI() async {
        let http = UpdateHTTPFixture()
        http.respond(latest: .init(status: 200, body: Self.releaseJSON(tag: "v1.1.0")),
                     manifest: .init(status: 429, body: Data(), headers: ["retry-after": "60"]))
        let limited = AppUpdateStore(currentVersion: "1.0.0", client: http.client)
        await expect(limited.checkForUpdates(), equals: .error(currentVersion: "1.0.0", operation: .check, code: .rateLimited, availableVersion: nil))
        XCTAssertNotNil(limited.rateLimitedUntil)

        http.respond(latest: .init(status: 200, body: Self.releaseJSON(tag: "v1.1.0")),
                     manifest: .init(status: 503, body: Data()))
        let unavailable = AppUpdateStore(currentVersion: "1.0.0", client: http.client)
        await expect(unavailable.checkForUpdates(), equals: .error(currentVersion: "1.0.0", operation: .check, code: .network, availableVersion: nil))
        XCTAssertFalse(http.requests.contains(UpdateHTTPFixture.latestPath))
    }

    func testManifestRedirectOffGitHubIsNotFollowed() async {
        let http = UpdateHTTPFixture()
        http.respond(latest: .init(status: 200, body: Self.releaseJSON(tag: "v1.1.0")),
                     manifest: .init(status: 302, body: Data(), redirect: "https://\(http.host)/elsewhere"))
        let store = AppUpdateStore(currentVersion: "1.0.0", client: http.client)
        await expect(store.checkForUpdates(), equals: .error(currentVersion: "1.0.0", operation: .check, code: .network, availableVersion: nil))
        XCTAssertEqual(http.requests, [UpdateHTTPFixture.manifestPath])
    }

    /// Where GitHub can't be reached (mainland China without a VPN) the check goes through the
    /// mirrors in turn, and the one that answered is asked first next time.
    func testUnreachableGitHubIsCheckedThroughAMirrorThatIsThenAskedFirst() async {
        let http = UpdateHTTPFixture(mirrors: 2)
        http.respond(latest: .init(status: 200, body: Self.releaseJSON(tag: "v1.1.0")),
                     manifest: .init(status: 0, body: Data(), error: .cannotConnectToHost))
        http.respond(mirror: 0, manifest: .init(status: 200, body: Data("<html>busy</html>".utf8)))
        http.respond(mirror: 1, manifest: .init(status: 200, body: Self.releaseJSON(tag: "v1.1.0")))
        let store = AppUpdateStore(currentVersion: "1.0.0", client: http.client)
        await expect(store.checkForUpdates(), equals: .manual(currentVersion: "1.0.0", availableVersion: "1.1.0"))
        XCTAssertEqual(http.requests, [UpdateHTTPFixture.manifestPath])
        XCTAssertEqual(http.requests(mirror: 0), [http.mirrored(UpdateHTTPFixture.manifestPath)])
        XCTAssertEqual(http.requests(mirror: 1), [http.mirrored(UpdateHTTPFixture.manifestPath)])

        await expect(store.checkForUpdates(), equals: .manual(currentVersion: "1.0.0", availableVersion: "1.1.0"))
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(http.requests(mirror: 0).count, 1)
        XCTAssertEqual(http.requests(mirror: 1).count, 2)
    }

    /// Only an unreachable GitHub sends a check to the mirrors; GitHub's own answers stand, and
    /// when no route works the failure reported is GitHub's.
    func testGitHubsOwnAnswersAreNotTakenToTheMirrors() async {
        let http = UpdateHTTPFixture(mirrors: 1)
        http.respond(latest: .init(status: 200, body: Self.releaseJSON(tag: "v1.1.0")),
                     manifest: .init(status: 429, body: Data(), headers: ["retry-after": "60"]))
        http.respond(mirror: 0, manifest: .init(status: 200, body: Self.releaseJSON(tag: "v1.1.0")))
        let limited = AppUpdateStore(currentVersion: "1.0.0", client: http.client)
        await expect(limited.checkForUpdates(), equals: .error(currentVersion: "1.0.0", operation: .check, code: .rateLimited, availableVersion: nil))
        XCTAssertEqual(http.requests(mirror: 0), [])

        let unreachable = UpdateHTTPFixture(mirrors: 1)
        unreachable.respond(latest: .init(status: 200, body: Data()), manifest: .init(status: 0, body: Data(), error: .timedOut))
        unreachable.respond(mirror: 0, manifest: .init(status: 0, body: Data(), error: .cannotFindHost))
        let store = AppUpdateStore(currentVersion: "1.0.0", client: unreachable.client)
        await expect(store.checkForUpdates(), equals: .error(currentVersion: "1.0.0", operation: .check, code: .network, availableVersion: nil))
        XCTAssertEqual(unreachable.requests(mirror: 0).count, 1)
    }

    /// A manifest's release page is opened only on github.com; one a mirror rewrote is not.
    func testReleasePageOffGitHubFallsBackToTheReleasesList() throws {
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.releaseJSON(tag: "v1.1.0")) as? [String: Any])
        payload["html_url"] = "https://evil.example/download"
        let release = try GitHubReleaseParser.decode(JSONSerialization.data(withJSONObject: payload))
        XCTAssertEqual(release.htmlURL, AppUpdateConfiguration.releasesURL)
        XCTAssertEqual(try GitHubReleaseParser.decode(Self.releaseJSON(tag: "v1.1.0")).htmlURL.host, "github.com")
    }

    func testConcurrentChecksShareOneRequestAndHideDownloadPaths() async {
        let fixture = Fixture()
        fixture.client.release = fixture.release(version: "1.1.0")
        fixture.client.fetchGate = Gate()
        async let first = fixture.store.checkForUpdates()
        async let second = fixture.store.checkForUpdates()
        await fixture.client.fetchGate?.waitUntilEntered()
        XCTAssertEqual(fixture.client.fetchCalls, 1)
        fixture.client.fetchGate?.open()
        _ = await (first, second)
        XCTAssertEqual(fixture.store.state, .available(currentVersion: "1.0.0", availableVersion: "1.1.0"))

        await fixture.store.downloadUpdate()
        XCTAssertEqual(fixture.store.state, .ready(currentVersion: "1.0.0", availableVersion: "1.1.0"))
        XCTAssertFalse("\(fixture.store.state)".contains("private"))
        XCTAssertTrue(fixture.revealed.isEmpty)
    }

    func testDownloadRevealsTheVerifiedAppOnlyWhenItCannotInstallInPlace() async {
        let elsewhere = Fixture()
        elsewhere.installer.canInstallInPlace = false
        elsewhere.client.release = elsewhere.release(version: "1.1.0")
        await elsewhere.store.checkForUpdates()
        await expect(elsewhere.store.downloadUpdate(), equals: .ready(currentVersion: "1.0.0", availableVersion: "1.1.0"))
        XCTAssertTrue(elsewhere.opened.isEmpty)
        XCTAssertEqual(elsewhere.revealed, [elsewhere.destination])

        let inPlace = Fixture()
        inPlace.client.release = inPlace.release(version: "1.1.0")
        await inPlace.store.checkForUpdates()
        await expect(inPlace.store.downloadUpdate(), equals: .ready(currentVersion: "1.0.0", availableVersion: "1.1.0"))
        XCTAssertTrue(inPlace.opened.isEmpty)
        XCTAssertTrue(inPlace.revealed.isEmpty)

        inPlace.store.revealDownloadedUpdate()
        XCTAssertEqual(inPlace.revealed, [inPlace.destination])
    }

    func testOldImagesAreDiscardedBeforeADownloadAndAtLaunchButNotTheReadyOne() async {
        let launch = Fixture()
        await launch.store.discardStaleDownloads()
        XCTAssertEqual(launch.discarded, [nil])

        let fixture = Fixture()
        fixture.client.release = fixture.release(version: "1.1.0")
        await fixture.store.checkForUpdates()
        await expect(fixture.store.downloadUpdate(), equals: .ready(currentVersion: "1.0.0", availableVersion: "1.1.0"))
        XCTAssertEqual(fixture.discarded, [nil])
        await fixture.store.discardStaleDownloads()
        XCTAssertEqual(fixture.discarded, [nil, fixture.destination])
    }

    func testUnverifiedDownloadIsNeverOfferedForManualInstallation() async {
        for canInstall in [false, true] {
            let fixture = Fixture()
            fixture.installer.canInstallInPlace = canInstall
            fixture.installer.prepareError = AppUpdateIssue(code: .verification, detail: "Untrusted or older app")
            fixture.client.release = fixture.release(version: "1.1.0")
            await fixture.store.checkForUpdates()
            await expect(fixture.store.downloadUpdate(), equals: .error(
                currentVersion: "1.0.0", operation: .download, code: .verification, availableVersion: "1.1.0"))
            fixture.store.revealDownloadedUpdate()
            XCTAssertTrue(fixture.opened.isEmpty)
            XCTAssertTrue(fixture.revealed.isEmpty)
        }
    }

    func testBackgroundUpdateWaitsForExplicitDownloadConfirmation() async {
        let inPlace = Fixture()
        inPlace.client.release = inPlace.release(version: "1.1.0")
        await expect(inPlace.store.checkInBackground(), equals: .available(currentVersion: "1.0.0", availableVersion: "1.1.0"))
        XCTAssertEqual(inPlace.client.downloadCalls, 0)
        // Dismissing the prompt and a later scheduled check still do not download.
        await expect(inPlace.store.checkInBackground(), equals: .available(currentVersion: "1.0.0", availableVersion: "1.1.0"))
        XCTAssertEqual(inPlace.client.downloadCalls, 0)
        await expect(inPlace.store.downloadUpdate(), equals: .ready(currentVersion: "1.0.0", availableVersion: "1.1.0"))
        await expect(inPlace.store.checkInBackground(), equals: .ready(currentVersion: "1.0.0", availableVersion: "1.1.0"))
        XCTAssertEqual(inPlace.client.downloadCalls, 1)

        // Outside Applications a download would reveal the verified app in Finder unasked.
        let elsewhere = Fixture()
        elsewhere.installer.canInstallInPlace = false
        elsewhere.client.release = elsewhere.release(version: "1.1.0")
        await expect(elsewhere.store.checkInBackground(), equals: .available(currentVersion: "1.0.0", availableVersion: "1.1.0"))
        XCTAssertEqual(elsewhere.client.downloadCalls, 0)
        XCTAssertTrue(elsewhere.opened.isEmpty)

        let current = Fixture()
        current.client.release = current.release(version: "1.0.0")
        await expect(current.store.checkInBackground(), equals: .upToDate(currentVersion: "1.0.0"))
        XCTAssertEqual(current.client.downloadCalls, 0)
    }

    func testDownloadProgressIsClampedAndInstallRequiresReadyState() async {
        XCTAssertEqual(AppUpdateProgress.clamped(transferred: 1_500, total: 1_000, rate: 500).percent, 100)
        XCTAssertEqual(AppUpdateProgress.clamped(transferred: 1_500, total: 1_000, rate: 500).transferred, 1_000)
        let fixture = Fixture()
        fixture.client.release = fixture.release(version: "1.1.0")
        fixture.client.progressEvents = [(1_500, 1_000, 500)]
        await fixture.store.installUpdate()
        XCTAssertEqual(fixture.store.state, .error(currentVersion: "1.0.0", operation: .install, code: .configuration, availableVersion: nil))
        XCTAssertEqual(fixture.installer.installCalls, 0)

        await fixture.store.checkForUpdates()
        await fixture.store.downloadUpdate()
        XCTAssertEqual(fixture.store.state, .ready(currentVersion: "1.0.0", availableVersion: "1.1.0"))
        await fixture.store.installUpdate()
        XCTAssertEqual(fixture.scheduled.count, 1)
        fixture.scheduled[0]()
        XCTAssertEqual(fixture.installer.installCalls, 1)
        XCTAssertEqual(fixture.terminateCalls, 1)
    }

    func testAnInstallIsPendingOnlyOnceTheInstallerIsWaitingForTheAppToQuit() async {
        let fixture = Fixture()
        fixture.client.release = fixture.release(version: "1.1.0")
        let gate = Gate()
        await fixture.store.checkForUpdates()
        await fixture.store.downloadUpdate()
        fixture.installer.prepareGate = gate
        XCTAssertFalse(fixture.store.isInstallPending, "an update that is only downloaded")

        let install = Task { await fixture.store.installUpdate() }
        await gate.waitUntilEntered()
        XCTAssertFalse(fixture.store.isInstallPending, "a Quit while the update is prepared is the user's")
        gate.open()
        await install.value
        XCTAssertFalse(fixture.store.isInstallPending, "prepared, but the installer has not been started")

        var pendingWhenTheAppWasAskedToQuit: Bool?
        fixture.recorder.onTerminate = { pendingWhenTheAppWasAskedToQuit = fixture.store.isInstallPending }
        fixture.scheduled[0]()

        XCTAssertEqual(pendingWhenTheAppWasAskedToQuit, true, "the quit the update asks for is the update's")
    }

    func testAnInstallThatCouldNotStartIsNotPending() async {
        let fixture = Fixture()
        fixture.client.release = fixture.release(version: "1.1.0")
        fixture.installer.installError = AppUpdateIssue(code: .permission, detail: "EACCES")
        await fixture.store.checkForUpdates()
        await fixture.store.downloadUpdate()
        await fixture.store.installUpdate()
        fixture.scheduled[0]()

        XCTAssertFalse(fixture.store.isInstallPending)
        XCTAssertEqual(fixture.terminateCalls, 0, "the app was never asked to quit")
    }

    func testErrorsAreClassifiedAndDownloadCanBeRetriedAfterCheck() async {
        let fixture = Fixture()
        fixture.client.fetchError = AppUpdateIssue(code: .verification, detail: "sha256 checksum mismatch at /private/update.dmg")
        await expect(fixture.store.checkForUpdates(), equals: .error(currentVersion: "1.0.0", operation: .check, code: .verification, availableVersion: nil))
        XCTAssertFalse("\(fixture.store.state)".contains("/private/update.dmg"))

        fixture.client.fetchError = nil
        fixture.client.release = fixture.release(version: "1.1.0")
        fixture.client.downloadError = URLError(.timedOut)
        await fixture.store.checkForUpdates()
        await expect(fixture.store.downloadUpdate(), equals: .error(currentVersion: "1.0.0", operation: .download, code: .network, availableVersion: "1.1.0"))

        fixture.client.downloadError = nil
        await fixture.store.checkForUpdates()
        await expect(fixture.store.downloadUpdate(), equals: .ready(currentVersion: "1.0.0", availableVersion: "1.1.0"))
    }

    func testInstallFailureKeepsDownloadedUpdateForRetry() async {
        let fixture = Fixture()
        fixture.client.release = fixture.release(version: "1.1.0")
        fixture.installer.installError = AppUpdateIssue(code: .permission, detail: "EACCES")
        await fixture.store.checkForUpdates()
        await fixture.store.downloadUpdate()
        await fixture.store.installUpdate()
        fixture.scheduled[0]()
        XCTAssertEqual(fixture.store.state, .error(currentVersion: "1.0.0", operation: .install, code: .permission, availableVersion: "1.1.0"))

        fixture.installer.installError = nil
        await fixture.store.installUpdate()
        XCTAssertEqual(fixture.scheduled.count, 2)
        fixture.scheduled[1]()
        XCTAssertEqual(fixture.installer.installCalls, 1)
    }

    func testInstallWatchdogFailsIfTheAppNeverQuits() async {
        let fixture = Fixture(installTimeout: .milliseconds(20))
        fixture.client.release = fixture.release(version: "1.1.0")
        await fixture.store.checkForUpdates()
        await fixture.store.downloadUpdate()
        await fixture.store.installUpdate()
        fixture.scheduled[0]()
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(fixture.store.state, .error(currentVersion: "1.0.0", operation: .install, code: .unknown, availableVersion: "1.1.0"))
        XCTAssertEqual(fixture.installer.installation.cancelCalls, 1)
    }

    func testARefusedQuitStopsTheWaitingInstallerOnceAndLeavesTheInstallToRetry() async {
        let fixture = Fixture()
        fixture.client.release = fixture.release(version: "1.1.0")
        await fixture.store.checkForUpdates()
        await fixture.store.downloadUpdate()
        await fixture.store.installUpdate()
        fixture.scheduled[0]()
        XCTAssertTrue(fixture.store.isInstallPending)

        await fixture.store.cancelPendingInstall()
        await fixture.store.cancelPendingInstall()

        XCTAssertEqual(fixture.installer.installation.cancelCalls, 1, "a second call finds nothing waiting")
        XCTAssertFalse(fixture.store.isInstallPending)
        XCTAssertEqual(fixture.store.state, .error(currentVersion: "1.0.0", operation: .install, code: .unknown, availableVersion: "1.1.0"))
        await fixture.store.installUpdate()
        XCTAssertEqual(fixture.scheduled.count, 2, "About offers the install again")
    }

    func testCallingOffAnInstallThatWasNeverStartedChangesNothing() async {
        let fixture = Fixture()
        fixture.client.release = fixture.release(version: "1.1.0")
        await fixture.store.checkForUpdates()
        await fixture.store.downloadUpdate()
        await fixture.store.installUpdate()
        XCTAssertEqual(fixture.store.state, .ready(currentVersion: "1.0.0", availableVersion: "1.1.0"))

        await fixture.store.cancelPendingInstall()

        XCTAssertEqual(fixture.installer.installation.cancelCalls, 0, "the installer was only prepared, not started")
        XCTAssertEqual(fixture.store.state, .ready(currentVersion: "1.0.0", availableVersion: "1.1.0"))
    }

    func testAnInstallerThatCannotBeStoppedStaysOwnedUntilItCan() async {
        let fixture = Fixture()
        fixture.client.release = fixture.release(version: "1.1.0")
        fixture.installer.installation.finishesCancellation = false
        await fixture.store.checkForUpdates()
        await fixture.store.downloadUpdate()
        await fixture.store.installUpdate()
        fixture.scheduled[0]()

        await fixture.store.cancelPendingInstall()
        XCTAssertTrue(fixture.store.isInstallPending, "a helper that is still alive keeps its owner")

        fixture.installer.installation.finishesCancellation = true
        await fixture.store.cancelPendingInstall()
        XCTAssertFalse(fixture.store.isInstallPending)
        XCTAssertEqual(fixture.installer.installation.cancelCalls, 2)
    }

    func testPreparationYieldsMainActorAndCancellationDiscardsItsResult() async {
        let fixture = Fixture()
        fixture.client.release = fixture.release(version: "1.1.0")
        let gate = Gate()
        await fixture.store.checkForUpdates()
        await fixture.store.downloadUpdate()
        fixture.installer.prepareGate = gate
        let install = Task { await fixture.store.installUpdate() }
        await gate.waitUntilEntered()
        XCTAssertEqual(fixture.store.state, .preparing(currentVersion: "1.0.0", availableVersion: "1.1.0"))
        XCTAssertTrue(fixture.store.state.isBusy)
        // Reaching this main-actor continuation proves preparation did not block it.
        await fixture.store.installUpdate()
        XCTAssertEqual(fixture.installer.preparationCalls, 2)
        fixture.store.cancel()
        gate.open()
        await install.value
        XCTAssertEqual(fixture.installer.discarded, [fixture.destination])
        XCTAssertTrue(fixture.scheduled.isEmpty)
        XCTAssertEqual(fixture.installer.installCalls, 0)
        XCTAssertEqual(fixture.store.state, .ready(currentVersion: "1.0.0", availableVersion: "1.1.0"))
        await fixture.store.installUpdate()
        XCTAssertEqual(fixture.scheduled.count, 1)
    }

    func testWatchdogCannotReleaseOwnershipUntilHelperCancellationFinishes() async {
        let fixture = Fixture(installTimeout: .milliseconds(10))
        fixture.client.release = fixture.release(version: "1.1.0")
        fixture.installer.installation.finishesCancellation = false
        await fixture.store.checkForUpdates()
        await fixture.store.downloadUpdate()
        await fixture.store.installUpdate()
        fixture.scheduled[0]()
        try? await Task.sleep(for: .milliseconds(60))
        await fixture.store.installUpdate()
        XCTAssertEqual(fixture.scheduled.count, 1)
        XCTAssertEqual(fixture.installer.installCalls, 1)
        fixture.installer.installation.finishesCancellation = true
        await fixture.store.installUpdate()
        XCTAssertEqual(fixture.scheduled.count, 2)
        fixture.scheduled[1]()
        XCTAssertEqual(fixture.installer.installCalls, 2)
    }

    func testReplacementExcludesASecondOwnerAndCancellationAllowsRetry() async throws {
        let fixture = try ReplacementFixture()
        defer { fixture.remove() }
        try fixture.makeApp(at: fixture.destination, marker: "old")
        try fixture.makeApp(at: fixture.source, marker: "new")
        let cancellation = fixture.root.appendingPathComponent("cancel")
        let helper = try AppUpdateInstaller.startReplacement(
            after: ProcessInfo.processInfo.processIdentifier, source: fixture.source,
            destination: fixture.destination, opener: fixture.opener.path, cancellation: cancellation)
        let owner = AppUpdateProcessTask(process: helper, cancellation: cancellation)
        XCTAssertThrowsError(try AppUpdateInstaller.startReplacement(
            after: ProcessInfo.processInfo.processIdentifier, source: fixture.source,
            destination: fixture.destination, opener: fixture.opener.path))
        let ended = await owner.cancel()
        XCTAssertTrue(ended)
        XCTAssertEqual(try fixture.marker(), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.log.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.path))
        try fixture.run()
        XCTAssertEqual(try fixture.marker(), "new")
        XCTAssertEqual(try fixture.reopened(), [fixture.destination.path])
    }

    /// `installUpdate()` schedules the restart from a main-actor task. The quit that follows
    /// waits in a nested run loop for the main-actor shutdown task; that task must get to run.
    func testScheduledRestartLetsTheQuitWaitRunMainActorWork() async {
        final class Flag { var raised = false }
        let drained = expectation(description: "main-actor work ran inside the nested run loop")
        AppUpdateStore.performOnMainRunLoop {
            let shutdown = Flag()
            Task { @MainActor in shutdown.raised = true }
            let deadline = Date().addingTimeInterval(2)
            while !shutdown.raised, Date() < deadline {
                _ = RunLoop.current.run(mode: .default, before: deadline)
            }
            if shutdown.raised { drained.fulfill() }
        }
        await fulfillment(of: [drained], timeout: 5)
    }

    func testBackgroundModesNeverOpenWindowsAndNeverInstallDuringOnboarding() async {
        for mode in AppUpdateMode.allCases {
            let fixture = Fixture()
            fixture.store.mode = mode
            fixture.client.release = fixture.release(version: "1.1.0")
            let coordinator = AppUpdateCoordinator(updater: fixture.store,
                isShuttingDown: { false }, isUnattended: { true }, menuChanged: {},
                showAbout: { XCTFail("Background work must not activate a window") },
                beforeAutomaticCheck: {}, windowClosed: {}, onboardingComplete: { false })
            await coordinator.runAutomaticCheck()
            for _ in 0..<5 { await Task.yield() }
            XCTAssertNil(coordinator.window)
            XCTAssertTrue(fixture.scheduled.isEmpty)
            XCTAssertEqual(fixture.client.downloadCalls, mode == .notify ? 0 : 1)
            XCTAssertTrue(fixture.revealed.isEmpty)
        }
        let manual = Fixture()
        manual.store.mode = .automatic
        manual.installer.canInstallInPlace = false
        manual.client.release = manual.release(version: "1.1.0")
        let coordinator = AppUpdateCoordinator(updater: manual.store,
            isShuttingDown: { false }, isUnattended: { true }, menuChanged: {},
            showAbout: { XCTFail("A manual installation stays passive") }, beforeAutomaticCheck: {}, windowClosed: {},
            onboardingComplete: { true })
        await coordinator.runAutomaticCheck()
        XCTAssertEqual(manual.client.downloadCalls, 0)
        XCTAssertTrue(manual.revealed.isEmpty)
    }

    func testPostponementPersistsAndExpiresWithoutDiscardingTheDownload() async {
        var clock = Date(timeIntervalSince1970: 100_000)
        let fixture = Fixture(now: { clock })
        fixture.store.mode = .automatic
        fixture.client.release = fixture.release(version: "1.1.0")
        await fixture.store.checkForUpdates()
        XCTAssertTrue(fixture.store.mayDownloadAutomatically)
        await fixture.store.downloadUpdate()
        fixture.store.postponeUpdate()
        XCTAssertTrue(fixture.store.isDeferred)
        XCTAssertTrue(fixture.store.hasDownloadedUpdate)
        let reopened = AppUpdateStore(currentVersion: "1.0.0", client: fixture.client, defaults: fixture.defaults, now: { clock })
        await reopened.checkForUpdates()
        XCTAssertEqual(reopened.mode, .automatic)
        XCTAssertTrue(reopened.isDeferred)
        clock.addTimeInterval(AppUpdatePolicy.postponement)
        XCTAssertFalse(reopened.isDeferred)
        XCTAssertTrue(fixture.store.hasDownloadedUpdate)
    }

    func testAutomaticInstallRechecksAfterPreparingAndAtHandoff() async {
        let fixture = Fixture()
        fixture.client.release = fixture.release(version: "1.1.0")
        await fixture.store.checkForUpdates()
        await fixture.store.downloadUpdate()
        let gate = Gate()
        fixture.installer.prepareGate = gate
        var unattended = true
        let install = Task { await fixture.store.installUpdate(automatically: true, allowed: { unattended }) }
        await gate.waitUntilEntered()
        unattended = false
        gate.open()
        await install.value
        XCTAssertTrue(fixture.scheduled.isEmpty)
        XCTAssertEqual(fixture.terminateCalls, 0)
        XCTAssertEqual(fixture.store.state, .ready(currentVersion: "1.0.0", availableVersion: "1.1.0"))
        fixture.installer.prepareGate = nil
        unattended = true
        await fixture.store.installUpdate(automatically: true, allowed: { unattended })
        unattended = false
        fixture.scheduled[0]()
        XCTAssertEqual(fixture.installer.installCalls, 0)
        XCTAssertEqual(fixture.terminateCalls, 0)
    }

    func testFailedRecheckKeepsCandidateNotesAndDownloadRetryDoesNotRefetch() async {
        let fixture = Fixture()
        fixture.client.release = fixture.release(version: "1.1.0", notes: "### Fixed\n- A change")
        await fixture.store.checkForUpdates()
        fixture.client.fetchError = URLError(.notConnectedToInternet)
        await fixture.store.checkForUpdates()
        XCTAssertEqual(fixture.store.state.availableVersion, "1.1.0")
        XCTAssertEqual(fixture.store.releaseNotes?.version, "1.1.0")
        fixture.client.fetchError = nil
        await fixture.store.checkForUpdates()
        fixture.client.downloadError = URLError(.timedOut)
        await fixture.store.downloadUpdate()
        let checks = fixture.client.fetchCalls
        fixture.client.downloadError = nil
        await fixture.store.retryUpdate()
        XCTAssertEqual(fixture.client.fetchCalls, checks)
        XCTAssertTrue(fixture.store.hasDownloadedUpdate)
    }

    func testCancelledRecheckRestoresTheDiscoveredVersion() async {
        let fixture = Fixture()
        fixture.client.release = fixture.release(version: "1.1.0")
        await fixture.store.checkForUpdates()
        let gate = Gate()
        fixture.client.fetchGate = gate
        let check = Task { await fixture.store.checkForUpdates() }
        await gate.waitUntilEntered()
        fixture.store.cancel()
        gate.open()
        await expect(check.value, equals: .available(currentVersion: "1.0.0", availableVersion: "1.1.0"))
    }

    func testCompleteCacheRestoresWithoutDownloadAndConfirmsOnlyTheRunningVersion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("update-cache-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = FakeAppUpdateClient()
        let asset = GitHubReleaseAsset(name: "WallpaperMachine-1.1.0-arm64.dmg",
            downloadURL: AppUpdateConfiguration.releasesURL, size: 3,
            digest: "sha256:" + SHA256.hash(data: Data("dmg".utf8)).map { String(format: "%02x", $0) }.joined())
        client.release = GitHubRelease(version: try XCTUnwrap(SemanticVersion("1.1.0")),
            htmlURL: AppUpdateConfiguration.releasesURL, prerelease: false, assets: [asset], notes: "### Fixed\n- Update")
        let defaults = TemporaryDefaults.makeForCurrentTest().defaults
        let workspace = AppUpdateWorkspace(archiveURL: { _, name in root.appendingPathComponent(name) },
            reveal: { _ in XCTFail("No Finder during restore") }, open: { _ in XCTFail("No windows during restore") },
            persistence: AppUpdatePersistence(directory: root))
        let original = AppUpdateStore(currentVersion: "1.0.0", client: client, installer: FakeInstaller(),
                                      workspace: workspace, defaults: defaults)
        await original.checkForUpdates()
        await original.downloadUpdate()
        XCTAssertEqual(client.downloadCalls, 1)
        let restored = AppUpdateStore(currentVersion: "1.0.0", client: client, installer: FakeInstaller(),
            workspace: workspace, scheduleInstall: { _ in }, terminate: {}, defaults: defaults)
        await restored.discardStaleDownloads()
        XCTAssertEqual(restored.state, .ready(currentVersion: "1.0.0", availableVersion: "1.1.0"))
        XCTAssertEqual(client.downloadCalls, 1)
        XCTAssertNil(restored.recentlyInstalledVersion)
        await restored.installUpdate()
        let upgraded = AppUpdateStore(currentVersion: "1.1.0", client: client, installer: FakeInstaller(),
            workspace: workspace, defaults: defaults)
        await upgraded.discardStaleDownloads()
        XCTAssertEqual(upgraded.recentlyInstalledVersion, "1.1.0")
        XCTAssertFalse(upgraded.hasDownloadedUpdate)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(asset.name).path))
    }

    private func expect(_ state: AppUpdateState, equals expected: AppUpdateState) {
        XCTAssertEqual(state, expected)
    }
}

/// A destination folder, an extracted copy in its own work folder, and an `open` stand-in
/// that records what the replacement script reopens instead of launching it.
private struct ReplacementFixture {
    let root: URL
    let destination: URL
    let source: URL
    let opener: URL
    let log: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mwe-update-swap-\(UUID().uuidString)")
        destination = root.appendingPathComponent("Applications/WallpaperMachine.app")
        source = root.appendingPathComponent("work/WallpaperMachine.app")
        opener = root.appendingPathComponent("open.sh")
        log = root.appendingPathComponent("opened.log")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/bash\necho \"$1\" >> \"\(log.path)\"\n".write(to: opener, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: opener.path)
    }

    func makeApp(at app: URL, marker: String) throws {
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try Data(marker.utf8).write(to: app.appendingPathComponent("Contents/marker"))
    }

    /// Waits on an already-exited process, so the script starts at once.
    func run() throws {
        let exited = Process()
        exited.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try exited.run()
        exited.waitUntilExit()
        let script = try AppUpdateInstaller.startReplacement(
            after: exited.processIdentifier, source: source, destination: destination, opener: opener.path)
        script.waitUntilExit()
    }

    func marker() throws -> String {
        try String(contentsOf: destination.appendingPathComponent("Contents/marker"), encoding: .utf8)
    }

    func leftovers() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path)
            .filter { $0 != destination.lastPathComponent && $0 != ".\(destination.lastPathComponent).update.lock" }
    }

    func reopened() throws -> [String] {
        try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private final class Fixture {
    let client = FakeAppUpdateClient()
    let installer = FakeInstaller()
    let store: AppUpdateStore
    let recorder = Recorder()
    var scheduled: [() -> Void] { recorder.scheduled }
    var revealed: [URL] { recorder.revealed }
    var opened: [URL] { recorder.opened }
    var discarded: [URL?] { recorder.discarded }
    var terminateCalls: Int { recorder.terminateCalls }
    let destination: URL
    /// The store's preferences (automatic installs, the skipped version), never the app's own.
    let defaults = TemporaryDefaults.makeForCurrentTest().defaults

    init(installTimeout: Duration = .seconds(45), installer: (any AppUpdateInstalling)? = nil,
         now: @escaping () -> Date = Date.init) {
        destination = FileManager.default.temporaryDirectory.appendingPathComponent("private/mwe-\(UUID().uuidString).dmg")
        let recorder = recorder
        let workspace = AppUpdateWorkspace(
            archiveURL: { [destination] _, _ in destination },
            reveal: { url in recorder.revealed.append(url) },
            open: { url in recorder.opened.append(url) },
            discardArchives: { keeping in recorder.discarded.append(keeping) }
        )
        store = AppUpdateStore(
            currentVersion: "1.0.0",
            client: client,
            installer: installer ?? self.installer,
            workspace: workspace,
            scheduleInstall: { work in recorder.scheduled.append(work) },
            terminate: {
                recorder.terminateCalls += 1
                recorder.onTerminate?()
            },
            installTimeout: installTimeout,
            defaults: defaults,
            now: now
        )
    }

    func release(version: String, assets: [GitHubReleaseAsset]? = nil, notes: String = "",
                 changelog: String = "") -> GitHubRelease {
        let defaultAssets = [
            GitHubReleaseAsset(
                name: "WallpaperMachine-\(version)-arm64.dmg",
                downloadURL: URL(string: "https://github.com/bobbyhuang-dev/WallpaperMachine/releases/download/v\(version)/WallpaperMachine-\(version)-arm64.dmg")!,
                size: 1_000,
                digest: nil
            )
        ]
        return GitHubRelease(
            version: SemanticVersion(version)!,
            htmlURL: URL(string: "https://github.com/bobbyhuang-dev/WallpaperMachine/releases/tag/v\(version)")!,
            prerelease: false,
            assets: assets ?? defaultAssets,
            notes: notes,
            changelog: changelog
        )
    }
}

private final class Recorder: @unchecked Sendable {
    var scheduled: [() -> Void] = []
    var revealed: [URL] = []
    var opened: [URL] = []
    var discarded: [URL?] = []
    var terminateCalls = 0
    var onTerminate: (() -> Void)?
}

private final class FakeAppUpdateClient: AppUpdateClient, @unchecked Sendable {
    var release: GitHubRelease?
    var fetchError: Error?
    var downloadError: Error?
    var sourceArchive: URL?
    var fetchGate: Gate?
    var progressEvents: [(Int64, Int64, Int64)] = []
    var fetchCalls = 0
    var downloadCalls = 0

    func fetchLatestRelease() async throws -> GitHubRelease? {
        fetchCalls += 1
        if let fetchGate { await fetchGate.wait() }
        if let fetchError { throw fetchError }
        return release
    }

    func download(_ asset: GitHubReleaseAsset, to destination: URL,
                  progress: @escaping @Sendable (Int64, Int64, Int64) -> Void) async throws {
        downloadCalls += 1
        if let downloadError { throw downloadError }
        for event in progressEvents { progress(event.0, event.1, event.2) }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let sourceArchive { try FileManager.default.copyItem(at: sourceArchive, to: destination) }
        else { try Data("dmg".utf8).write(to: destination) }
    }
}

private final class FakeInstaller: AppUpdateInstalling, @unchecked Sendable {
    var canInstallInPlace = true
    var installCalls = 0
    var installError: Error?
    var prepareGate: Gate?
    var prepareError: Error?
    var discarded: [URL] = []
    var preparationCalls = 0
    var installation = FakeInstallationTask()

    func prepareInstallation(archive: URL) async throws -> URL {
        preparationCalls += 1
        if let prepareGate { await prepareGate.wait() }
        if let prepareError { throw prepareError }
        return archive
    }

    func discardPreparation(_ extractedApp: URL) async { discarded.append(extractedApp) }

    func install(extractedApp: URL, replacing destination: URL) throws -> any AppUpdateInstallationTask {
        if let installError { throw installError }
        installCalls += 1
        return installation
    }
}

private final class FakeInstallationTask: AppUpdateInstallationTask, @unchecked Sendable {
    var cancelCalls = 0
    var finishesCancellation = true
    func cancel() async -> Bool { cancelCalls += 1; return finishesCancellation }
}

private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var entered = 0
    private var opened = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            entered += 1
            let enteredWaiters = self.enteredWaiters
            self.enteredWaiters = []
            if opened {
                lock.unlock()
                enteredWaiters.forEach { $0.resume() }
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
                enteredWaiters.forEach { $0.resume() }
            }
        }
    }

    func waitUntilEntered() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if entered > 0 {
                lock.unlock()
                continuation.resume()
            } else {
                enteredWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func open() {
        lock.lock()
        opened = true
        let waiters = self.waiters
        self.waiters = []
        lock.unlock()
        waiters.forEach { $0.resume() }
    }
}

private final class UpdateHTTPFixture {
    static let manifestPath = "/fixture/app/releases/latest/download/" + AppUpdateConfiguration.manifestName
    static let latestPath = "/repos/fixture/app/releases/latest"
    let host = "update-\(UUID().uuidString).invalid"
    let mirrorHosts: [String]
    let session: URLSession
    let client: GitHubReleaseClient

    init(mirrors: Int = 0) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateHTTPProtocol.self]
        session = GitHubReleaseClient.makeSession(configuration: configuration)
        mirrorHosts = (0..<mirrors).map { "mirror-\($0)-\(UUID().uuidString).invalid" }
        client = GitHubReleaseClient(session: session,
                                     manifestURL: URL(string: "https://\(host)\(Self.manifestPath)")!,
                                     latestURL: URL(string: "https://\(host)\(Self.latestPath)")!,
                                     mirrors: mirrorHosts.map { URL(string: "https://\($0)/")! })
    }

    /// The path a mirror sees for `path` on GitHub: the whole GitHub URL.
    func mirrored(_ path: String) -> String { "/https://\(host)\(path)" }

    func respond(mirror index: Int, manifest: UpdateHTTPProtocol.Response) {
        UpdateHTTPProtocol.register(mirrorHosts[index], routes: [mirrored(Self.manifestPath): manifest])
    }

    func requests(mirror index: Int) -> [String] { UpdateHTTPProtocol.requests(mirrorHosts[index]) }

    /// Releases published before the manifest existed have none, so it is absent unless given.
    func respond(latest: UpdateHTTPProtocol.Response,
                 repository: UpdateHTTPProtocol.Response = .init(status: 200, body: Data(#"{"id":1}"#.utf8)),
                 manifest: UpdateHTTPProtocol.Response = .init(status: 404, body: Data())) {
        UpdateHTTPProtocol.register(host, routes: [Self.manifestPath: manifest, Self.latestPath: latest,
                                                   "/repos/fixture/app": repository])
    }

    /// Paths requested so far, in order.
    var requests: [String] { UpdateHTTPProtocol.requests(host) }

    deinit {
        session.invalidateAndCancel()
        UpdateHTTPProtocol.remove(host)
        mirrorHosts.forEach(UpdateHTTPProtocol.remove)
    }
}

private final class UpdateHTTPProtocol: URLProtocol, @unchecked Sendable {
    struct Response: Sendable {
        let status: Int
        let body: Data
        var error: URLError.Code? = nil
        var headers: [String: String] = [:]
        var redirect: String? = nil
        /// Answers `Range: bytes=<n>-` with a 206 of the rest, as GitHub and the mirrors do.
        var honorsRange = false
        /// Ends the response after this many bytes of the body, like a connection closed early.
        var endsAfter: Int? = nil
        /// Delivers the body in this many pieces, a moment apart.
        var chunks = 1
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [String: [String: Response]] = [:]
    nonisolated(unsafe) private static var log: [String: [String]] = [:]
    nonisolated(unsafe) private static var rangeLog: [String: [String?]] = [:]
    static func register(_ host: String, routes: [String: Response]) {
        lock.withLock { self.routes[host] = routes }
    }
    static func requests(_ host: String) -> [String] { lock.withLock { log[host] ?? [] } }
    /// The `Range` header of each request so far, in order.
    static func ranges(_ host: String) -> [String?] { lock.withLock { rangeLog[host] ?? [] } }
    static func remove(_ host: String) {
        lock.withLock {
            routes.removeValue(forKey: host)
            log.removeValue(forKey: host)
            rangeLog.removeValue(forKey: host)
        }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let host = url.host else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let path = url.path.count > 1 && url.path.hasSuffix("/") ? String(url.path.dropLast()) : url.path
        let range = request.value(forHTTPHeaderField: "Range")
        let response = Self.lock.withLock { () -> Response? in
            Self.log[host, default: []].append(path)
            Self.rangeLog[host, default: []].append(range)
            return Self.routes[host]?[path]
        }
        guard let response else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        if let error = response.error {
            client?.urlProtocol(self, didFailWithError: URLError(error))
            return
        }
        var headers = response.headers.merging(["Content-Type": "application/json"]) { value, _ in value }
        if let redirect = response.redirect { headers["Location"] = redirect }
        var status = response.status
        var body = response.body
        if response.honorsRange, let range, range.hasPrefix("bytes="), range.hasSuffix("-"),
           let start = Int(range.dropFirst(6).dropLast()), start < body.count {
            status = 206
            headers["Content-Range"] = "bytes \(start)-\(body.count - 1)/\(body.count)"
            body = body.subdata(in: start..<body.count)
        }
        let http = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        if let redirect = response.redirect, let target = URL(string: redirect) {
            // Like the HTTP loader: a refused redirect delivers the 3xx response itself.
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: http)
        }
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        if let endsAfter = response.endsAfter {
            client?.urlProtocol(self, didLoad: Data(body.prefix(endsAfter)))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let size = max(1, (body.count + response.chunks - 1) / response.chunks)
        for offset in stride(from: 0, to: body.count, by: size) {
            if offset > 0 { Thread.sleep(forTimeInterval: 0.05) }
            client?.urlProtocol(self, didLoad: body.subdata(in: offset..<min(offset + size, body.count)))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private extension AppUpdateTests {
    static func releaseJSON(tag: String, prerelease: Bool = false, body: String = "",
                            assets: [(String, String, Int, String?)] = [], changelog: String? = nil) -> Data {
        let assetObjects: [[String: Any]] = assets.map { name, url, size, digest in
            var fields: [String: Any] = ["name": name, "browser_download_url": url, "size": size]
            if let digest { fields["digest"] = digest }
            return fields
        }
        var payload: [String: Any] = [
            "tag_name": tag,
            "html_url": "https://github.com/bobbyhuang-dev/WallpaperMachine/releases/tag/\(tag)",
            "prerelease": prerelease,
            "body": body,
            "assets": assetObjects,
        ]
        if let changelog { payload["changelog"] = changelog }
        return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
    }

    /// What an ad-hoc copy of this app satisfies: its identifier, with no certificate.
    static let adHocRequirement = #"identifier "app.wallpapermachine""#

    /// A minimal app bundle around a real Mach-O executable, signed ad hoc unless `signed` is
    /// false, so the installer's signature check has something genuine to read.
    static func makeApplication(in folder: URL, bundleIdentifier: String, version: String = "1.2.3",
                                signed: Bool = true) throws -> URL {
        let app = folder.appendingPathComponent("WallpaperMachine.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": bundleIdentifier, "CFBundleExecutable": "WallpaperMachine",
                                   "CFBundlePackageType": "APPL", "CFBundleShortVersionString": version,
                                   "LSMinimumSystemVersion": "15.0"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"),
                                         to: app.appendingPathComponent("Contents/MacOS/WallpaperMachine"))
        if signed { try signAdHoc(app) }
        return app
    }

    static func signAdHoc(_ app: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--sign", "-", app.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw AppUpdateIssue(code: .unknown, detail: "codesign exited \(process.terminationStatus)")
        }
    }

    /// A compressed HFS+ image shaped like the release: the app plus an `Applications` link.
    static func makeDiskImage(in root: URL, bundleIdentifier: String, withUnsignedSibling: Bool = false) throws -> URL {
        let source = root.appendingPathComponent("source", isDirectory: true)
        _ = try makeApplication(in: source, bundleIdentifier: bundleIdentifier)
        if withUnsignedSibling {
            let sibling = try makeApplication(in: root.appendingPathComponent("unsigned"),
                                              bundleIdentifier: "com.example.untrusted", signed: false)
            try FileManager.default.moveItem(at: sibling, to: source.appendingPathComponent("Install Update.app"))
        }
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("Applications").path,
                                                   withDestinationPath: "/Applications")
        let image = root.appendingPathComponent("WallpaperMachine-1.2.3-arm64.dmg")
        _ = try hdiutil(["create", "-srcfolder", source.path, "-volname", "WallpaperMachine 1.2.3",
                         "-fs", "HFS+", "-format", "UDZO", "-ov", image.path])
        return image
    }

    /// The devices `image` is attached as, according to `hdiutil info`; empty once detached.
    static func attachedDevices(of image: URL) throws -> [String] {
        let output = try hdiutil(["info", "-plist"])
        let info = try XCTUnwrap(PropertyListSerialization.propertyList(from: output, format: nil) as? [String: Any])
        let wanted = image.resolvingSymlinksInPath().path
        let images = info["images"] as? [[String: Any]] ?? []
        return images.compactMap { entry in
            guard let path = entry["image-path"] as? String,
                  URL(fileURLWithPath: path).resolvingSymlinksInPath().path == wanted else { return nil }
            let entities = entry["system-entities"] as? [[String: Any]] ?? []
            return entities.compactMap { $0["dev-entry"] as? String }.min() ?? path
        }
    }

    /// Leaves nothing attached if an assertion failed before the installer detached.
    static func forceDetach(_ image: URL) {
        for device in (try? attachedDevices(of: image)) ?? [] where device.hasPrefix("/dev/") {
            _ = try? hdiutil(["detach", "-force", device])
        }
    }

    @discardableResult
    static func hdiutil(_ arguments: [String]) throws -> Data {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw AppUpdateIssue(code: .unknown, detail: "hdiutil \(arguments.first ?? "") exited \(process.terminationStatus)")
        }
        return data
    }
}
