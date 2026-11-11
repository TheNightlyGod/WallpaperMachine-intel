import CryptoKit
import Darwin
import XCTest
@testable import WallpaperMachine

@MainActor
final class SteamCMDSetupTests: XCTestCase {
    private let preferenceKey = "WallpaperMachineSteamCMDPath"

    func testInstallPublishesFilesAndNewStoreDiscoversSameRuntime() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.store()
        store.install()
        try await finished(store)
        XCTAssertEqual(store.state, .ready)
        let executable = fixture.root.appendingPathComponent("SteamCMD/MacOS/steamcmd")
        XCTAssertEqual(store.selectedRuntime?.executableURL, executable)
        XCTAssertEqual(try String(contentsOf: executable, encoding: .utf8), "fixture-executable")
        XCTAssertEqual(try String(contentsOf: executable.deletingLastPathComponent().appendingPathComponent("steamconsole.dylib"), encoding: .utf8), "updated-library")
        XCTAssertEqual(fixture.defaults.string(forKey: preferenceKey), executable.path)
        XCTAssertGreaterThan(getxattr(executable.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW), 0)
        let second = fixture.store()
        await second.refresh()
        XCTAssertEqual(second.selectedRuntime, store.selectedRuntime)
        XCTAssertEqual(second.state, .ready)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.root.appendingPathComponent("SteamCMD/MacOS/Frameworks/Breakpad.framework/Versions/Current").path), "A")
        XCTAssertTrue(FileManager.default.fileExists(atPath: executable.deletingLastPathComponent().appendingPathComponent("package/steam_cmd_osx.manifest").path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).contains { $0.hasPrefix(".steamcmd-") })
    }

    func testInstalledRuntimeDownloadsAndImportsWorkshopWallpaper() async throws {
        let script = #"""
            #!/bin/sh
            set -eu
            install=''
            item=''
            while [ "$#" -gt 0 ]; do
                case "$1" in
                    +force_install_dir) shift; install="$1" ;;
                    +workshop_download_item) shift; [ "$1" = 431960 ]; shift; item="$1" ;;
                esac
                shift
            done
            [ -n "$install" ]
            [ "$item" = 123456 ]
            printf 'Steam Console Client\npassword: '
            IFS= read -r password
            [ "$password" = fixture-password ]
            printf '\nWaiting for user info...OK\nDownloading item %s ...\n' "$item"
            content="$install/steamapps/workshop/content/431960/$item"
            mkdir -p "$content"
            printf '%s' '{"title":"Installed runtime fixture","type":"video","file":"movie.mp4"}' > "$content/project.json"
            printf '\000\001\177\200\377fixture-media' > "$content/movie.mp4"
            printf 'Success. Downloaded item %s\n' "$item"
            """#
        let entries = Self.bootstrapEntries.map { entry in
            entry.path == "steamcmd" ? TarEntry(entry.path, contents: script + "\n") : entry
        }
        let fixture = try Fixture(body: Self.tar(entries))
        defer { fixture.remove() }
        let downloader = WorkshopDownloader(sessionDirectory: fixture.root.appendingPathComponent("Session"),
                                            runtimeProvider: FixtureRuntime(blocked: nil))
        let store = fixture.store(downloader: downloader)
        do {
            store.install()
            try await finished(store)
            XCTAssertEqual(store.state, .ready)
            let executable = try XCTUnwrap(store.selectedRuntime?.executableURL)
            XCTAssertEqual(executable, fixture.root.appendingPathComponent("SteamCMD/MacOS/steamcmd"))
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path))
            let item = WorkshopItem(id: "123456", title: "Installed runtime fixture", creator: "Test",
                                    summary: "", previewURL: nil, tags: ["Video"], size: 0, subscriptions: 0)
            let library = fixture.root.appendingPathComponent("Library")
            downloader.start(item: item, username: "localtest", executable: executable, library: library,
                             rememberSession: false, onImported: {})
            try await waitUntil { downloader.prompt == .password || !downloader.isRunning }
            XCTAssertEqual(downloader.prompt, .password, downloader.errorMessage ?? "Installed runtime must reach its PTY login prompt")
            downloader.submitSecret("fixture-password")
            try await waitUntil { !downloader.isRunning }
            XCTAssertNil(downloader.errorMessage)
            XCTAssertEqual(downloader.downloadedID, item.id)
            let imported = library.appendingPathComponent(item.id)
            let manifest = try Data(contentsOf: imported.appendingPathComponent("project.json"))
            XCTAssertEqual(try JSONSerialization.jsonObject(with: manifest) as? [String: String],
                           ["title": "Installed runtime fixture", "type": "video", "file": "movie.mp4"])
            XCTAssertEqual(try Data(contentsOf: imported.appendingPathComponent("movie.mp4")),
                           Data([0x00, 0x01, 0x7f, 0x80, 0xff]) + Data("fixture-media".utf8))
            await downloader.shutdown()
            await store.shutdown()
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).contains {
                $0.hasPrefix(".WallpaperMachine-workshop-") || $0.hasPrefix(".WallpaperMachine-import-")
            })
        } catch {
            await downloader.shutdown()
            await store.shutdown()
            throw error
        }
    }

    func testInvalidSelectionPreservesPreviousRuntimeAndPreference() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let old = try fixture.oldRuntime()
        let store = fixture.store()
        await store.refresh()
        store.selectExisting(at: fixture.root.appendingPathComponent("missing"))
        try await finished(store)
        XCTAssertEqual(store.selectedRuntime?.executableURL, old)
        XCTAssertEqual(fixture.defaults.string(forKey: preferenceKey), old.path)
        XCTAssertEqual(try String(contentsOf: old, encoding: .utf8), "old-executable")
        guard case .failed = store.state else { return XCTFail("Invalid selection must not report Ready") }
        await store.refresh()
        XCTAssertEqual(store.state, .ready)
        XCTAssertEqual(store.selectedRuntime?.executableURL, old)
    }

    func testInvalidExplicitPreferenceDoesNotFallBackToManagedRuntime() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.oldRuntime()
        let invalid = fixture.root.appendingPathComponent("explicit-missing").path
        fixture.defaults.set(invalid, forKey: preferenceKey)
        let store = fixture.store()
        await store.refresh()
        XCTAssertNil(store.selectedRuntime)
        XCTAssertEqual(fixture.defaults.string(forKey: preferenceKey), invalid)
        guard case .failed = store.state else { return XCTFail("Explicit invalid selection must remain visible") }
    }

    func testDiscoverySkipsIncompleteCandidateForCompleteLegacyRuntime() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let newer = try fixture.oldRuntime()
        try FileManager.default.removeItem(at: newer.deletingLastPathComponent().appendingPathComponent("steamconsole.dylib"))
        let legacy = fixture.root.appendingPathComponent("SteamCMD/steamcmd")
        try Data("legacy-executable".utf8).write(to: legacy)
        try Data("legacy-library".utf8).write(to: legacy.deletingLastPathComponent().appendingPathComponent("steamconsole.dylib"))
        fixture.defaults.removeObject(forKey: preferenceKey)
        let store = fixture.store()
        await store.refresh()
        XCTAssertEqual(store.state, .ready)
        XCTAssertEqual(store.selectedRuntime?.executableURL, legacy)
        XCTAssertEqual(try String(contentsOf: legacy, encoding: .utf8), "legacy-executable")
        XCTAssertNil(fixture.defaults.string(forKey: preferenceKey))
    }

    func testRefreshClearsRemovedRuntime() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let executable = try fixture.oldRuntime()
        let store = fixture.store()
        await store.refresh()
        try FileManager.default.removeItem(at: executable)
        await store.refresh()
        XCTAssertNil(store.selectedRuntime)
        guard case .failed = store.state else { return XCTFail("A removed explicit runtime must fail discovery") }
    }

    func testSuccessfulReinstallReplacesWholeContainer() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let old = try fixture.oldRuntime()
        let sentinel = old.deletingLastPathComponent().appendingPathComponent("old-only")
        try Data("old".utf8).write(to: sentinel)
        let store = fixture.store()
        await store.refresh()
        store.install(replacingExisting: true)
        try await finished(store)
        XCTAssertEqual(store.state, .ready)
        XCTAssertEqual(try String(contentsOf: old, encoding: .utf8), "fixture-executable")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sentinel.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).contains { $0.hasPrefix(".steamcmd-backup-") })
    }

    func testUnconfirmedReinstallLeavesOldFilesUntouched() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let old = try fixture.oldRuntime()
        let store = fixture.store()
        await store.refresh()
        store.install()
        try await finished(store)
        XCTAssertEqual(try String(contentsOf: old, encoding: .utf8), "old-executable")
        XCTAssertEqual(store.selectedRuntime?.executableURL, old)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("smoke-started").path))
        guard case .failed = store.state else { return XCTFail("Replacement requires confirmation") }
    }

    func testExitZeroWithoutCompleteRuntimeDoesNotReplaceOldInstallation() async throws {
        let fixture = try Fixture(body: Self.tar(Self.bootstrapEntries.filter { $0.path != "steamconsole.dylib" }))
        defer { fixture.remove() }
        let old = try fixture.oldRuntime()
        let store = fixture.store()
        await store.refresh()
        store.install(replacingExisting: true)
        try await finished(store)
        XCTAssertEqual(try String(contentsOf: old, encoding: .utf8), "old-executable")
        XCTAssertEqual(fixture.defaults.string(forKey: preferenceKey), old.path)
        XCTAssertEqual(store.selectedRuntime?.executableURL, old)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("smoke-started").path))
        guard case .failed(let issue) = store.state else { return XCTFail("Incomplete packages must fail") }
        XCTAssertEqual(issue.kind, .invalidArchive)
    }

    func testRuntimeRemovedDuringSmokeDoesNotOverwriteOldPreferenceOrFiles() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let old = try fixture.oldRuntime()
        let store = fixture.store(mode: .removeBeforePublication)
        await store.refresh()
        store.install(replacingExisting: true)
        try await finished(store)
        XCTAssertEqual(try String(contentsOf: old, encoding: .utf8), "old-executable")
        XCTAssertEqual(fixture.defaults.string(forKey: preferenceKey), old.path)
        XCTAssertEqual(store.selectedRuntime?.executableURL, old)
        guard case .failed(let issue) = store.state else { return XCTFail("Failed publication must not become Ready") }
        XCTAssertEqual(issue.kind, .incompleteRuntime)
    }

    func testSignatureGatekeeperAndAppleSiliconFailuresNeverRunSmoke() async throws {
        for kind: SteamCMDSetupIssue.Kind in [.invalidSignature, .securityApprovalRequired, .appleSiliconRequired] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let store = fixture.store(blocked: kind)
            store.install()
            try await finished(store)
            guard case .failed(let issue) = store.state else { XCTFail("Security failure must stop installation"); continue }
            XCTAssertEqual(issue.kind, kind)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("smoke-started").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("SteamCMD").path))
            XCTAssertNil(fixture.defaults.string(forKey: preferenceKey))
            if kind != .securityApprovalRequired {
                XCTAssertNil(store.retainedCandidateURL)
                XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).contains { $0.hasPrefix(".steamcmd-setup-") })
            } else {
                let candidate = try XCTUnwrap(store.retainedCandidateURL)
                XCTAssertTrue(FileManager.default.fileExists(atPath: candidate.appendingPathComponent("steamcmd").path))
            }
        }
    }

    func testUnsafeArchiveEntriesCannotWriteOutsideOrExecute() async throws {
        let outside = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("steamcmd-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let sentinel = outside.appendingPathComponent("sentinel")
        try Data("untouched".utf8).write(to: sentinel)
        let payloads: [[TarEntry]] = [
            [TarEntry("../outside", contents: "escape")],
            [TarEntry(sentinel.path, contents: "overwrite")],
            [TarEntry("escape", type: "2", link: outside.path), TarEntry("escape/sentinel", contents: "overwrite")],
            [TarEntry("hardlink", type: "1", link: sentinel.path)],
            [TarEntry("cycle.framework/a", type: "2", link: "b"), TarEntry("cycle.framework/b", type: "2", link: "a")],
            [TarEntry("fifo", type: "6")]
        ]
        for entries in payloads {
            let fixture = try Fixture(body: Self.tar(Self.bootstrapEntries + entries))
            defer { fixture.remove() }
            let store = fixture.store()
            store.install()
            try await finished(store)
            guard case .failed = store.state else { XCTFail("Unsafe archive must fail"); continue }
            XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "untouched")
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("smoke-started").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("SteamCMD").path))
            XCTAssertNil(fixture.defaults.string(forKey: preferenceKey))
        }
    }

    func testNetworkAndCorruptArchivesNeverPublish() async throws {
        let responses: [(Data, Int, [String: String])] = [
            (Data("unavailable".utf8), 503, [:]),
            (Data("<html>not an archive</html>".utf8), 200, [:]),
            (Data([0x1f, 0x8b, 0x08, 0, 0, 0, 0, 0, 0, 3, 0xff]), 200, [:]),
            (Data("oversized".utf8), 200, ["Content-Length": String(64 * 1024 * 1024 + 1)])
        ]
        for (body, status, headers) in responses {
            let fixture = try Fixture(body: body, status: status, headers: headers)
            defer { fixture.remove() }
            let store = fixture.store()
            store.install()
            try await finished(store)
            guard case .failed = store.state else { XCTFail("Bad response must fail"); continue }
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("SteamCMD").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("smoke-started").path))
            XCTAssertNil(fixture.defaults.string(forKey: preferenceKey))
        }
    }

    func testSmallGzipWithOversizedExpandedFileIsRejectedBeforeExtraction() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let payload = fixture.root.appendingPathComponent("oversized-payload")
        XCTAssertTrue(FileManager.default.createFile(atPath: payload.path, contents: nil))
        let handle = try FileHandle(forWritingTo: payload)
        try handle.truncate(atOffset: 256 * 1024 * 1024 + 1)
        try handle.close()
        let archive = fixture.root.appendingPathComponent("oversized.tar.gz")
        let status = try await SteamCMDProcessRunner().run(executable: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["--format=ustar", "-c", "-z", "-f", archive.path, "-C", fixture.root.path, payload.lastPathComponent],
            workingDirectory: fixture.root, environment: ["PATH": "/usr/bin:/bin", "LC_ALL": "C", "COPYFILE_DISABLE": "1"], onOutput: { _ in })
        XCTAssertEqual(status, 0)
        let body = try Data(contentsOf: archive)
        XCTAssertLessThan(body.count, 64 * 1024 * 1024)
        BootstrapURLProtocol.register(fixture.identifier, response: .init(body: body, status: 200, headers: [:], hold: false, redirect: nil))
        let store = fixture.store()
        store.install()
        try await finished(store)
        guard case .failed(let issue) = store.state else { return XCTFail("Expanded-size limit must reject the archive") }
        XCTAssertEqual(issue.kind, .invalidArchive)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("extraction-started").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("smoke-started").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("SteamCMD").path))
        XCTAssertNil(fixture.defaults.string(forKey: preferenceKey))
    }

    func testCancellationAtTraversalHandoffWaitsForCleanupAndCannotPublish() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.store(mode: .pauseAfterExtraction)
        store.install()
        try await waitUntil { FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("extraction-finished").path) }
        await store.shutdown()
        XCTAssertEqual(store.state, .cancelled)
        XCTAssertFalse(store.isBusy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("smoke-started").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("SteamCMD").path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).contains { $0.hasPrefix(".steamcmd-setup-") })
    }

    func testForeignAndDowngradeRedirectsAreRejected() async throws {
        for destination in ["https://untrusted.invalid/steamcmd.tar.gz", "http://steamcdn-a.akamaihd.net/steamcmd.tar.gz"] {
            let fixture = try Fixture(redirect: URL(string: destination)!)
            defer { fixture.remove() }
            let store = fixture.store()
            store.install()
            try await finished(store)
            guard case .failed(let issue) = store.state else { XCTFail("Unsafe redirect must fail"); continue }
            XCTAssertEqual(issue.kind, .network)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("smoke-started").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("SteamCMD").path))
        }
    }

    func testRejectedRedirectRetainsItsFailureWhenFinalResponseArrivesBeforeCancellation() async throws {
        for destination in ["https://untrusted.invalid/steamcmd", "http://steamcdn-a.akamaihd.net/client/steam_cmd_osx"] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            var failures: [SteamCMDSetupIssue] = []
            for deliversFinalResponse in [false, true] {
                let events = RejectedRedirectEvents(destination: URL(string: destination)!, deliversFinalResponse: deliversFinalResponse)
                let output = fixture.root.appendingPathComponent("download-\(deliversFinalResponse)")
                let download = SteamCMDDownload(source: SteamCMDPackageManifest.url, destination: output,
                    maximum: SteamCMDPackageManifest.maximumSize, configuration: fixture.configuration,
                    progress: { received, _ in events.rejectRedirect(received: received) })
                events.attach(download)
                do {
                    _ = try await download.start()
                    XCTFail("A rejected redirect must fail the download")
                } catch let issue as SteamCMDSetupIssue {
                    failures.append(issue)
                }
                XCTAssertEqual(try Data(contentsOf: output).count, 0)
            }
            XCTAssertEqual(failures.count, 2)
            XCTAssertEqual(failures.first?.kind, .network)
            // Preserve the original error value, without pinning localized diagnostic wording.
            XCTAssertEqual(failures.first, failures.last)
        }
    }

    func testUnsafeManagedSymlinkDoesNotTouchExternalRuntime() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let outside = fixture.root.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("sentinel")
        try Data("untouched".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("SteamCMD"), withDestinationURL: outside)
        let store = fixture.store()
        store.install(replacingExisting: true)
        try await finished(store)
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "untouched")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("smoke-started").path))
        guard case .failed(let issue) = store.state else { return XCTFail("Symlink destination must fail") }
        XCTAssertEqual(issue.kind, .fileSystem)
    }

    func testShutdownDuringDownloadPreventsPublicationAndCleansStaging() async throws {
        let fixture = try Fixture(holdDownload: true)
        defer { fixture.remove() }
        let store = fixture.store()
        store.install()
        try await waitUntil { if case .downloading = store.state { return true }; return false }
        await store.shutdown()
        XCTAssertEqual(store.state, .cancelled)
        XCTAssertFalse(store.isBusy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("SteamCMD").path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).contains { $0.hasPrefix(".steamcmd-setup-") })
    }

    func testShutdownDuringSmokeReapsChildrenBeforeCleaningStaging() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.store(mode: .waitForCancellation)
        store.install()
        let started = fixture.root.appendingPathComponent("child-started")
        try await waitUntil { FileManager.default.fileExists(atPath: started.path) }
        let child = try XCTUnwrap(Int32(String(contentsOf: started, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        await store.shutdown()
        XCTAssertEqual(store.state, .cancelled)
        try await waitUntil { kill(child, 0) != 0 }
        try await Task.sleep(for: .seconds(3))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("late-write").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("SteamCMD").path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).contains { $0.hasPrefix(".steamcmd-setup-") })
    }

    func testCancellationImmediatelyBeforePublicationPreservesOldInstallation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let old = try fixture.oldRuntime()
        let store = fixture.store(mode: .waitBeforePublication)
        await store.refresh()
        store.install(replacingExisting: true)
        try await waitUntil { FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("smoke-started").path) }
        await store.shutdown()
        XCTAssertEqual(store.state, .cancelled)
        XCTAssertEqual(store.selectedRuntime?.executableURL, old)
        XCTAssertEqual(fixture.defaults.string(forKey: preferenceKey), old.path)
        XCTAssertEqual(try String(contentsOf: old, encoding: .utf8), "old-executable")
    }

    func testLateCancellationCannotUndoSuccessfulPublication() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.store()
        store.install()
        try await finished(store)
        store.cancel()
        await store.shutdown()
        XCTAssertEqual(store.state, .ready)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(store.selectedRuntime?.executableURL.path)))
    }

    func testRealRunnerCancelsOwnedGroupWithoutLateWrite() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("steamcmd-process-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let task = Task {
            try await SteamCMDProcessRunner().run(executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "(sleep 3; printf late > late-write) & echo $! > child-started; wait"],
                workingDirectory: root, environment: ["PATH": "/usr/bin:/bin"], onOutput: { _ in })
        }
        try await waitUntil { FileManager.default.fileExists(atPath: root.appendingPathComponent("child-started").path) }
        let child = try XCTUnwrap(Int32(String(contentsOf: root.appendingPathComponent("child-started"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled child must not report success") }
        catch is CancellationError {}
        try await waitUntil { kill(child, 0) != 0 }
        try await Task.sleep(for: .seconds(3))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("late-write").path))
    }

    func testRealRunnerDoesNotLeaveChildrenAfterLeaderExitsSuccessfully() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("steamcmd-exited-process-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let status = try await SteamCMDProcessRunner().run(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "(sleep 3; printf late > late-write) & echo $! > child-started; exit 0"],
            workingDirectory: root, environment: ["PATH": "/usr/bin:/bin"], onOutput: { _ in })
        XCTAssertEqual(status, 0)
        let child = try XCTUnwrap(Int32(String(contentsOf: root.appendingPathComponent("child-started"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        try await waitUntil { kill(child, 0) != 0 }
        try await Task.sleep(for: .seconds(3))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("late-write").path))
    }

    func testBlockedCandidateSurvivesShutdownAndReopenWithPreviousSelection() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let old = try fixture.oldRuntime()
        let store = fixture.store(blocked: .securityApprovalRequired)
        await store.refresh()
        store.install(replacingExisting: true)
        try await finished(store)
        let root = try XCTUnwrap(store.retainedCandidateURL)
        let executable = root.appendingPathComponent("steamcmd")
        XCTAssertGreaterThan(getxattr(executable.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW), 0)
        XCTAssertEqual(try String(contentsOf: executable, encoding: .utf8), "fixture-executable")
        await store.shutdown()
        let reopened = fixture.store(blocked: .securityApprovalRequired)
        await reopened.refresh()
        XCTAssertEqual(reopened.retainedCandidateURL, root)
        XCTAssertEqual(reopened.selectedRuntime?.executableURL, old)
        guard case .failed(let issue) = reopened.state else { return XCTFail("Reopening must preserve the security failure") }
        XCTAssertEqual(issue.kind, .securityApprovalRequired)
        var metadata = stat()
        XCTAssertEqual(lstat(fixture.root.appendingPathComponent("SteamCMDPending.json").path, &metadata), 0)
        XCTAssertEqual(metadata.st_mode & 0o777, 0o600)
    }

    func testRetryUsesSameApprovedRuntimeWithoutAnotherDownload() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let provider = ApprovalFixtureRuntime()
        let store = fixture.store(provider: provider)
        store.install()
        try await finished(store)
        let candidate = try await store.prepareApproval()
        var before = stat()
        XCTAssertEqual(lstat(candidate.rootURL.appendingPathComponent("steamcmd").path, &before), 0)
        try await provider.approve(candidate)
        // Removing the registered response makes any redownload fail, rather than merely counting a helper call.
        BootstrapURLProtocol.remove(fixture.identifier)
        store.retryInstallation()
        try await finished(store)
        XCTAssertEqual(store.state, .ready)
        let installed = try XCTUnwrap(store.selectedRuntime?.executableURL)
        var after = stat()
        XCTAssertEqual(lstat(installed.path, &after), 0)
        XCTAssertEqual(after.st_ino, before.st_ino)
        XCTAssertEqual(try String(contentsOf: installed.deletingLastPathComponent().appendingPathComponent("steamconsole.dylib"), encoding: .utf8), "updated-library")
        XCTAssertNil(store.retainedCandidateURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("SteamCMDPending.json").path))
    }

    func testApprovedRuntimeSurvivesReopenAndResumesWithoutDownload() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let provider = ApprovalFixtureRuntime()
        let store = fixture.store(provider: provider)
        store.install()
        try await finished(store)
        let candidate = try await store.prepareApproval()
        try await provider.approve(candidate)
        await store.shutdown()
        BootstrapURLProtocol.remove(fixture.identifier)
        let reopened = fixture.store(provider: provider)
        let reopenedCandidate = try await reopened.prepareApproval()
        XCTAssertEqual(reopenedCandidate, candidate)
        reopened.approveRetainedCandidate(reopenedCandidate)
        try await finished(reopened)
        XCTAssertEqual(reopened.state, .ready)
        XCTAssertEqual(try String(contentsOf: fixture.root.appendingPathComponent("smoke-count"), encoding: .utf8), "1")
    }

    func testStaleApprovalCannotAuthorizeChangedOrDiscardedCandidate() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let provider = ApprovalFixtureRuntime()
        let store = fixture.store(provider: provider)
        store.install()
        try await finished(store)
        let candidate = try await store.prepareApproval()
        try Data("changed-bytes".utf8).write(to: candidate.rootURL.appendingPathComponent("steamcmd"))
        store.approveRetainedCandidate(candidate)
        try await finished(store)
        guard case .failed(let issue) = store.state else { return XCTFail("Stale approval must fail") }
        XCTAssertEqual(issue.kind, .invalidSelection)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("smoke-started").path))
        store.discardRetainedCandidate()
        try await finished(store)
        store.approveRetainedCandidate(candidate)
        XCTAssertNil(store.retainedCandidateURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: candidate.rootURL.path))
        XCTAssertNil(fixture.store(provider: provider).retainedCandidateURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("SteamCMD").path))
    }

    func testCancelledRetainedRetryCannotResurrectCandidate() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let provider = ApprovalFixtureRuntime()
        let store = fixture.store(mode: .waitForCancellation, provider: provider)
        store.install()
        try await finished(store)
        let candidate = try await store.prepareApproval()
        try await provider.approve(candidate)
        store.retryInstallation()
        try await waitUntil { FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("child-started").path) }
        await store.shutdown()
        XCTAssertEqual(store.state, .cancelled)
        XCTAssertNil(store.retainedCandidateURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: candidate.rootURL.path))
        XCTAssertNil(fixture.store(provider: provider).retainedCandidateURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("SteamCMDPending.json").path))
    }

    func testPendingMetadataCannotFollowExternalOrSubstitutedPaths() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.store(blocked: .securityApprovalRequired)
        store.install()
        try await finished(store)
        let root = try XCTUnwrap(store.retainedCandidateURL)
        let staging = root.deletingLastPathComponent().deletingLastPathComponent()
        let outside = fixture.root.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("sentinel")
        try Data("untouched".utf8).write(to: sentinel)
        try FileManager.default.removeItem(at: staging)
        try FileManager.default.createSymbolicLink(at: staging, withDestinationURL: outside)
        XCTAssertNil(fixture.store().retainedCandidateURL)
        store.discardRetainedCandidate()
        try await finished(store)
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "untouched")
        let metadata = fixture.root.appendingPathComponent("SteamCMDPending.json")
        let invalid: [String: Any] = ["directory": "../external", "device": 0, "inode": 0,
                                      "stage": "bootstrap", "replacingExisting": false, "needsRosetta": false, "detail": "external"]
        try JSONSerialization.data(withJSONObject: invalid).write(to: metadata)
        XCTAssertEqual(chmod(metadata.path, 0o600), 0)
        let reopened = fixture.store()
        XCTAssertNil(reopened.retainedCandidateURL)
        reopened.discardRetainedCandidate()
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "untouched")
        XCTAssertFalse(FileManager.default.fileExists(atPath: metadata.path))
        try FileManager.default.createSymbolicLink(at: metadata, withDestinationURL: sentinel)
        XCTAssertNil(fixture.store().retainedCandidateURL)
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "untouched")
    }

    func testDeletedRetainedCandidateCannotBeResurrectedByRetryOrReopen() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.store(blocked: .securityApprovalRequired)
        store.install()
        try await finished(store)
        let root = try XCTUnwrap(store.retainedCandidateURL)
        try FileManager.default.removeItem(at: root)
        BootstrapURLProtocol.remove(fixture.identifier)
        store.retryInstallation()
        try await finished(store)
        XCTAssertNil(store.retainedCandidateURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("smoke-started").path))
        XCTAssertNil(fixture.store().retainedCandidateURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("SteamCMDPending.json").path))
    }

    func testDiscardDuringRetainedRetryWaitsForOwnedChildAndCannotRestart() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let provider = ApprovalFixtureRuntime()
        let store = fixture.store(mode: .waitForCancellation, provider: provider)
        store.install()
        try await finished(store)
        let candidate = try await store.prepareApproval()
        try await provider.approve(candidate)
        store.retryInstallation()
        let marker = fixture.root.appendingPathComponent("child-started")
        try await waitUntil { FileManager.default.fileExists(atPath: marker.path) }
        let child = try XCTUnwrap(Int32(String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        store.discardRetainedCandidate()
        store.install()
        await store.shutdown()
        try await waitUntil { kill(child, 0) != 0 }
        XCTAssertFalse(store.isBusy)
        XCTAssertNil(store.retainedCandidateURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: candidate.rootURL.path))
        XCTAssertNil(fixture.store(provider: provider).retainedCandidateURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("SteamCMD").path))
        XCTAssertEqual(try String(contentsOf: fixture.root.appendingPathComponent("smoke-count"), encoding: .utf8), "1")
    }

    func testMalformedAndOversizedManifestsNeverPublish() async throws {
        let seed = try Fixture()
        defer { seed.remove() }
        let valid = String(decoding: try XCTUnwrap(BootstrapURLProtocol.routes(seed.identifier)["/client/steam_cmd_osx"]).body, as: UTF8.self)
        let manifests = ["", "osx {}", "\"osx\" {", "\"osx\" { \"version\" \"1\\2\" }",
            valid.replacingOccurrences(of: "steamcmd_bins_osx", with: "other"),
            valid.replacingOccurrences(of: ".zip.", with: ".tar."),
            valid.replacingOccurrences(of: ".zip.", with: ".zip.g"),
            valid.replacingOccurrences(of: "\"size\"", with: "\"missing\""),
            String(repeating: " ", count: 65537)]
        for manifest in manifests {
            let fixture = try Fixture()
            defer { fixture.remove() }
            BootstrapURLProtocol.replace(fixture.identifier, path: "/client/steam_cmd_osx",
                response: .init(body: Data(manifest.utf8), status: 200, headers: [:], hold: false, redirect: nil))
            try await assertInvalidInstall(fixture)
        }
    }

    func testBothPackageChecksumsAreRequired() async throws {
        for field in ["sha2", "file"] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let routes = BootstrapURLProtocol.routes(fixture.identifier)
            let original = try XCTUnwrap(routes["/client/steam_cmd_osx"])
            let manifest = try SteamCMDPackageManifest(data: original.body)
            let package = try XCTUnwrap(manifest.packages.first)
            let old = field == "sha2" ? package.sha256 : package.sha1
            let bad = String(repeating: "0", count: old.count)
            let changed = String(decoding: original.body, as: UTF8.self).replacingOccurrences(of: old, with: bad)
            if field == "file" {
                BootstrapURLProtocol.replace(fixture.identifier, path: "/client/" + package.file.replacingOccurrences(of: old, with: bad),
                    response: try XCTUnwrap(routes["/client/" + package.file]))
            }
            BootstrapURLProtocol.replace(fixture.identifier, path: "/client/steam_cmd_osx",
                response: .init(body: Data(changed.utf8), status: 200, headers: [:], hold: false, redirect: nil))
            try await assertInvalidInstall(fixture)
        }
    }

    func testHTTPContentLengthUsesWireEncodingWhileChecksumsUseDecodedBytes() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for (path, response) in BootstrapURLProtocol.routes(fixture.identifier) {
            // URLSession has already decoded gzip before invoking the download delegate.
            BootstrapURLProtocol.replace(fixture.identifier, path: path,
                response: .init(body: response.body, status: 200,
                    headers: ["Content-Encoding": "gzip", "Content-Length": "1"], hold: false, redirect: nil))
        }
        let store = fixture.store()
        store.install()
        try await finished(store)
        XCTAssertEqual(store.state, .ready)
    }

    func testManifestNetworkFailureAndPackageLengthsNeverPublish() async throws {
        for variant in 0..<5 {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let routes = BootstrapURLProtocol.routes(fixture.identifier)
            let path = variant == 0 ? "/client/steam_cmd_osx" : try XCTUnwrap(routes.keys.first { $0.contains("steamcmd_osx.zip.") })
            let original = try XCTUnwrap(routes[path])
            let body = variant == 3 ? original.body.dropLast() : variant == 4 ? original.body + Data([1]) : original.body
            let headers = variant == 1 ? ["Content-Length": String(body.count + 1)] : variant == 2 ? ["Content-Length": "1"] : [:]
            BootstrapURLProtocol.replace(fixture.identifier, path: path,
                response: .init(body: body, status: variant == 0 ? 503 : 200, headers: headers, hold: false, redirect: nil))
            try await assertInvalidInstall(fixture, kind: variant == 0 ? .network : .invalidArchive)
        }
    }

    func testDuplicateFileAcrossPackagesIsRejectedBeforeExtraction() async throws {
        // The second package also contains bins-marker.
        let fixture = try Fixture(body: Self.tar(Self.bootstrapEntries + [TarEntry("./bins-marker", contents: "duplicate")]))
        defer { fixture.remove() }
        try await assertInvalidInstall(fixture)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("extraction-started").path))
    }

    func testZipBackslashPathsAndPermissions() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = fixture.root.appendingPathComponent("zip-source")
        let nested = source.appendingPathComponent("Frameworks\\Breakpad.framework")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("framework".utf8).write(to: nested.appendingPathComponent("Breakpad"))
        for name in ["steamcmd", "steamconsole.dylib", "crashhandler.dylib"] {
            // Mach-O magic without execute bits exercises the zip permission repair, not signature verification.
            try Data([0xcf, 0xfa, 0xed, 0xfe, 0, 0, 0, 0]).write(to: source.appendingPathComponent(name))
        }
        try Data("plain".utf8).write(to: source.appendingPathComponent("readme"))
        let archive = fixture.root.appendingPathComponent("fixture.zip")
        let status = try await SteamCMDProcessRunner().run(executable: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["--format", "zip", "-c", "-f", archive.path, "-C", source.path, "."],
            workingDirectory: fixture.root, environment: ["PATH": "/usr/bin:/bin", "COPYFILE_DISABLE": "1"], onOutput: { _ in })
        XCTAssertEqual(status, 0)
        BootstrapURLProtocol.register(fixture.identifier, response: .init(body: try Data(contentsOf: archive), status: 200, headers: [:], hold: false, redirect: nil))
        let store = fixture.store()
        store.install()
        try await finished(store)
        XCTAssertEqual(store.state, .ready)
        let root = try XCTUnwrap(store.selectedRuntime?.rootURL)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Frameworks/Breakpad.framework/Breakpad"), encoding: .utf8), "framework")
        for (name, mode): (String, mode_t) in [("steamcmd", 0o755), ("crashhandler.dylib", 0o755), ("readme", 0o644), ("Frameworks", 0o755), ("package/steam_cmd_osx.manifest", 0o644)] {
            var info = stat()
            XCTAssertEqual(lstat(root.appendingPathComponent(name).path, &info), 0)
            XCTAssertEqual(info.st_mode & 0o777, mode)
        }
    }

    func testRetiredBootstrapRecordIsDiscardedOnInit() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.store(blocked: .securityApprovalRequired)
        store.install()
        try await finished(store)
        let candidate = try XCTUnwrap(store.retainedCandidateURL)
        let record = fixture.root.appendingPathComponent("SteamCMDPending.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: record)) as? [String: Any])
        json["stage"] = "bootstrap"
        json["needsRosetta"] = true
        try JSONSerialization.data(withJSONObject: json).write(to: record)
        let reopened = fixture.store()
        XCTAssertNil(reopened.retainedCandidateURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: candidate.deletingLastPathComponent().deletingLastPathComponent().path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.path))
    }

    func testIntelOnlyManagedCopyReportsNativeReinstall() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let binary = try fixture.oldRuntime()
        var header = Data()
        for word: UInt32 in [0xfeedfacf, SteamCMDArchitecture.x86_64, 3, 2, 0, 0, 0, 0] {
            var little = word.littleEndian
            withUnsafeBytes(of: &little) { header.append(contentsOf: $0) }
        }
        try header.write(to: binary)
        XCTAssertEqual(chmod(binary.path, 0o755), 0)
        fixture.defaults.removeObject(forKey: preferenceKey)
        let store = fixture.store(provider: ManagedNativeFixtureRuntime(root: fixture.root))
        await store.refresh()
        guard case .failed(let issue) = store.state else { return XCTFail("Intel copy must offer reinstall") }
        XCTAssertEqual(issue.kind, .appleSiliconRequired)
        XCTAssertNil(store.selectedRuntime)
    }

    func testDownloadProgressNeverMovesBackwards() async throws {
        let fixture = try Fixture(body: Self.tar(Self.bootstrapEntries + [TarEntry("large", contents: String(repeating: "x", count: 512 * 1024))]))
        defer { fixture.remove() }
        let store = fixture.store()
        store.install()
        var last: Int64 = 0
        var observed = false
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while store.isBusy {
            guard ContinuousClock.now < deadline else {
                await store.shutdown()
                XCTFail("SteamCMD setup did not finish before the deadline")
                return
            }
            if case .downloading(let received, let expected) = store.state, let expected {
                observed = true
                XCTAssertGreaterThanOrEqual(received, last)
                XCTAssertLessThanOrEqual(received, expected)
                last = received
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(observed)
        XCTAssertEqual(store.state, .ready)
    }

    func testUpdateCheckReplacesAManagedCopyValveNoLongerLists() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let old = try fixture.oldRuntime()
        try fixture.recordInstalledVersion("1700000000")
        let store = fixture.store()
        await store.refresh()
        XCTAssertTrue(store.updateCheckIsDue())
        let updated = await store.updateIfOutdated()
        XCTAssertTrue(updated)
        XCTAssertEqual(store.state, .ready)
        XCTAssertEqual(try String(contentsOf: old, encoding: .utf8), "fixture-executable")
        XCTAssertEqual(SteamCMDSetupStore.installedVersion(at: old.deletingLastPathComponent()), "1788292693")
        XCTAssertEqual(store.selectedRuntime?.executableURL.path, old.path)
        XCTAssertFalse(store.updateCheckIsDue(), "One check a day")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).contains { $0.hasPrefix(".steamcmd-") })
    }

    func testUpdateCheckLeavesACurrentCopyAndComesBackADayLater() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let old = try fixture.oldRuntime()
        try fixture.recordInstalledVersion("1788292693")
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let store = fixture.store(now: { clock })
        await store.refresh()
        let updated = await store.updateIfOutdated()
        XCTAssertFalse(updated)
        XCTAssertEqual(store.state, .ready)
        XCTAssertEqual(try String(contentsOf: old, encoding: .utf8), "old-executable")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("smoke-started").path))
        clock += SteamCMDSetupStore.failureUpdateCheckInterval
        XCTAssertFalse(store.updateCheckIsDue())
        XCTAssertTrue(store.updateCheckIsDue(within: SteamCMDSetupStore.failureUpdateCheckInterval),
                      "A sign-in that ended for no reason may look again sooner")
        clock += SteamCMDSetupStore.updateCheckInterval
        XCTAssertTrue(store.updateCheckIsDue())
        clock = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertTrue(store.updateCheckIsDue(), "A clock set back does not postpone the check")
    }

    func testUnreadableManifestKeepsTheInstalledCopyWithoutComplaint() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let old = try fixture.oldRuntime()
        BootstrapURLProtocol.replace(fixture.identifier, path: "/client/steam_cmd_osx",
                                     response: .init(body: Data(), status: 503, headers: [:], hold: false, redirect: nil))
        let store = fixture.store()
        await store.refresh()
        let updated = await store.updateIfOutdated()
        XCTAssertFalse(updated)
        XCTAssertEqual(store.state, .ready)
        XCTAssertEqual(store.selectedRuntime?.executableURL.path, old.path)
        XCTAssertEqual(try String(contentsOf: old, encoding: .utf8), "old-executable")
        XCTAssertFalse(store.updateCheckIsDue(), "An offline Mac is not asked again on every download")
    }

    func testAFailedUpdateKeepsTheWorkingCopyQuietly() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let old = try fixture.oldRuntime()
        try fixture.recordInstalledVersion("1700000000")
        for path in BootstrapURLProtocol.routes(fixture.identifier).keys where path != "/client/steam_cmd_osx" {
            BootstrapURLProtocol.replace(fixture.identifier, path: path,
                                         response: .init(body: Data("truncated".utf8), status: 200, headers: [:], hold: false, redirect: nil))
        }
        let store = fixture.store()
        await store.refresh()
        let updated = await store.updateIfOutdated()
        XCTAssertFalse(updated)
        XCTAssertEqual(store.state, .ready, "Downloads go on with the copy in use; the next day tries again")
        XCTAssertEqual(store.selectedRuntime?.executableURL.path, old.path)
        XCTAssertEqual(try String(contentsOf: old, encoding: .utf8), "old-executable")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).contains { $0.hasPrefix(".steamcmd-") })
    }

    func testAnUpdateMacOSHoldsForApprovalIsShown() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let old = try fixture.oldRuntime()
        try fixture.recordInstalledVersion("1700000000")
        let store = fixture.store(blocked: .securityApprovalRequired)
        await store.refresh()
        let updated = await store.updateIfOutdated()
        XCTAssertFalse(updated)
        guard case .failed(let issue) = store.state else { return XCTFail("Approval is the user's: \(store.state)") }
        XCTAssertEqual(issue.kind, .securityApprovalRequired)
        XCTAssertNotNil(store.retainedCandidateURL)
        XCTAssertEqual(store.selectedRuntime?.executableURL.path, old.path, "Downloads keep the copy in use meanwhile")
        XCTAssertFalse(store.updateCheckIsDue(), "A retained candidate waits for the user's decision")
    }

    func testUpdateCheckLeavesALocatedCopyAlone() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let elsewhere = fixture.root.appendingPathComponent("Located/steamcmd")
        try FileManager.default.createDirectory(at: elsewhere.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("located".utf8).write(to: elsewhere)
        try Data("library".utf8).write(to: elsewhere.deletingLastPathComponent().appendingPathComponent("steamconsole.dylib"))
        fixture.defaults.set(elsewhere.path, forKey: preferenceKey)
        let store = fixture.store()
        await store.refresh()
        XCTAssertEqual(store.selectedRuntime?.executableURL.path, elsewhere.path)
        XCTAssertFalse(store.updateCheckIsDue())
        let updated = await store.updateIfOutdated()
        XCTAssertFalse(updated)
        XCTAssertEqual(try String(contentsOf: elsewhere, encoding: .utf8), "located")
    }

    private func assertInvalidInstall(_ fixture: Fixture, kind: SteamCMDSetupIssue.Kind = .invalidArchive) async throws {
        let store = fixture.store()
        store.install()
        try await finished(store)
        guard case .failed(let issue) = store.state else { return XCTFail("Invalid response must fail: \(store.state)") }
        XCTAssertEqual(issue.kind, kind)
        XCTAssertNil(store.retainedCandidateURL)
        XCTAssertNil(fixture.defaults.string(forKey: preferenceKey))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("SteamCMD").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("smoke-started").path))
    }

    private func finished(_ store: SteamCMDSetupStore) async throws { try await waitUntil { !store.isBusy } }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw TestFailure.timeout }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private enum TestFailure: Error { case timeout }

    @MainActor
    private struct Fixture {
        let root: URL
        let defaults: UserDefaults
        let configuration: URLSessionConfiguration
        let identifier: String
        init(body: Data? = nil, status: Int = 200,
             headers: [String: String] = [:], holdDownload: Bool = false, redirect: URL? = nil) throws {
            identifier = UUID().uuidString
            defaults = TemporaryDefaults.makeForCurrentTest().defaults
            let temporaryPath = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
            defer { free(temporaryPath) }
            root = URL(fileURLWithPath: String(cString: temporaryPath), isDirectory: true)
                .appendingPathComponent("SteamCMDSetupTests.\(identifier)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            configuration = .ephemeral
            configuration.protocolClasses = [BootstrapURLProtocol.self]
            configuration.httpAdditionalHeaders = ["X-SteamCMD-Test": identifier]
            BootstrapURLProtocol.register(identifier, response: .init(body: body ?? SteamCMDSetupTests.tar(SteamCMDSetupTests.bootstrapEntries), status: status, headers: headers, hold: holdDownload, redirect: redirect))
        }
        func remove() {
            BootstrapURLProtocol.remove(identifier)
            try? FileManager.default.removeItem(at: root)
        }
        func store(mode: FixtureRunner.Mode = .complete, blocked: SteamCMDSetupIssue.Kind? = nil,
                   downloader: WorkshopDownloader? = nil, provider suppliedProvider: (any SteamCMDRuntimeProviding)? = nil,
                   now: @escaping () -> Date = Date.init) -> SteamCMDSetupStore {
            let provider = suppliedProvider ?? FixtureRuntime(blocked: blocked)
            // Exercise Apple's public /var alias while expecting canonical publication paths.
            let support = URL(fileURLWithPath: root.path.replacingOccurrences(of: "/private/var/", with: "/var/"), isDirectory: true)
            return SteamCMDSetupStore(downloader: downloader ?? WorkshopDownloader(sessionDirectory: root.appendingPathComponent("Session"), runtimeProvider: provider),
                supportDirectory: support, defaults: defaults, sessionConfiguration: configuration,
                runtimeProvider: provider, processRunner: FixtureRunner(root: root, mode: mode), now: now)
        }
        /// Records `version` as the manifest the managed copy was installed from.
        func recordInstalledVersion(_ version: String) throws {
            let served = String(decoding: try XCTUnwrap(BootstrapURLProtocol.routes(identifier)["/client/steam_cmd_osx"]).body, as: UTF8.self)
            let record = root.appendingPathComponent("SteamCMD/MacOS/package")
            try FileManager.default.createDirectory(at: record, withIntermediateDirectories: true)
            try Data(served.replacingOccurrences(of: "\"1788292693\"", with: "\"\(version)\"").utf8)
                .write(to: record.appendingPathComponent("steam_cmd_osx.manifest"))
        }
        func oldRuntime() throws -> URL {
            let directory = root.appendingPathComponent("SteamCMD/MacOS")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let executable = directory.appendingPathComponent("steamcmd")
            try Data("old-executable".utf8).write(to: executable)
            try Data("old-library".utf8).write(to: directory.appendingPathComponent("steamconsole.dylib"))
            defaults.set(executable.path, forKey: "WallpaperMachineSteamCMDPath")
            return executable
        }
    }

    fileprivate struct TarEntry {
        let path: String
        let contents: String
        let type: Character
        let link: String
        init(_ path: String, contents: String = "", type: Character = "0", link: String = "") {
            self.path = path; self.contents = contents; self.type = type; self.link = link
        }
    }
    private static var bootstrapEntries: [TarEntry] {
        [TarEntry("steamcmd", contents: "fixture-executable"), TarEntry("steamcmd.sh", contents: "fixture-wrapper"),
         TarEntry("steamconsole.dylib", contents: "updated-library"),
         TarEntry("crashhandler.dylib", contents: "fixture-library"),
         TarEntry("Frameworks/Breakpad.framework/Versions/A/Breakpad", contents: "fixture-framework"),
         TarEntry("Frameworks/Breakpad.framework/Versions/Current", type: "2", link: "A"),
         TarEntry("Frameworks/Breakpad.framework/Breakpad", type: "2", link: "Versions/Current/Breakpad")]
    }
    /// Raw POSIX ustar lets tests encode malicious entries without first writing them to the filesystem.
    nonisolated fileprivate static func tar(_ entries: [TarEntry]) -> Data {
        var archive = Data()
        for entry in entries {
            var header = [UInt8](repeating: 0, count: 512)
            func put(_ value: String, _ offset: Int, _ count: Int) {
                let bytes = Array(value.utf8.prefix(count))
                header.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
            }
            let payload = Data(entry.contents.utf8)
            put(entry.path, 0, 100)
            put("0000755", 100, 8)
            put("0000000", 108, 8); put("0000000", 116, 8)
            put(String(format: "%011o", payload.count), 124, 12)
            put("00000000000", 136, 12)
            put("        ", 148, 8)
            put(String(entry.type), 156, 1)
            put(entry.link, 157, 100)
            put("ustar", 257, 6); put("00", 263, 2)
            let checksum = header.reduce(0) { $0 + Int($1) }
            put(String(format: "%06o", checksum) + "\0 ", 148, 8)
            archive.append(contentsOf: header)
            archive.append(payload)
            if payload.count % 512 != 0 { archive.append(Data(repeating: 0, count: 512 - payload.count % 512)) }
        }
        archive.append(Data(repeating: 0, count: 1024))
        return gzip(archive)
    }

    /// A gzip stream with stored DEFLATE blocks keeps malicious ustar fixtures deterministic.
    nonisolated private static func gzip(_ bytes: Data) -> Data {
        var result = Data([0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 3])
        var offset = 0
        while offset < bytes.count {
            let length = min(65535, bytes.count - offset)
            result.append(offset + length == bytes.count ? 1 : 0)
            let complement = 65535 - length
            result.append(contentsOf: [UInt8(length & 255), UInt8(length >> 8), UInt8(complement & 255), UInt8(complement >> 8)])
            result.append(bytes.subdata(in: offset..<(offset + length)))
            offset += length
        }
        var crc: UInt32 = 0xffffffff
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xedb88320 : 0) }
        }
        for value in [~crc, UInt32(truncatingIfNeeded: bytes.count)] {
            result.append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
        }
        return result
    }
}

private struct ManagedNativeFixtureRuntime: SteamCMDRuntimeProviding {
    let root: URL
    private var service: SteamCMDRuntimeService { SteamCMDRuntimeService(approvalDirectory: root.appendingPathComponent("Approvals")) }
    func resolve(executable: URL) throws -> SteamCMDRuntime {
        guard executable.path.hasPrefix(root.path + "/") else {
            throw SteamCMDSetupIssue(kind: .invalidSelection, detail: "Outside test fixture")
        }
        return try service.resolve(executable: executable)
    }
    func validate(at root: URL) async throws { try await service.validate(at: root) }
    func prepare(executable: URL, staging: URL) async throws -> URL { try await service.prepare(executable: executable, staging: staging) }
}

private struct FixtureRuntime: SteamCMDRuntimeProviding {
    let blocked: SteamCMDSetupIssue.Kind?
    func resolve(executable: URL) throws -> SteamCMDRuntime {
        guard FileManager.default.fileExists(atPath: executable.path) else {
            throw SteamCMDSetupIssue(kind: .invalidSelection, detail: "Missing fixture executable")
        }
        return SteamCMDRuntime(rootURL: executable.deletingLastPathComponent(), executableURL: executable)
    }
    func validate(at root: URL) async throws {
        if root.path.contains(".steamcmd-setup-"), let blocked {
            throw SteamCMDSetupIssue(kind: blocked, detail: "Fixture security boundary")
        }
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("steamconsole.dylib").path),
              FileManager.default.fileExists(atPath: root.appendingPathComponent("steamcmd").path) else {
            throw SteamCMDSetupIssue(kind: .incompleteRuntime, detail: "Missing complete fixture runtime")
        }
    }
    func prepare(executable: URL, staging: URL) async throws -> URL {
        let runtime = try resolve(executable: executable)
        try FileManager.default.copyItem(at: runtime.rootURL, to: staging)
        return staging.appendingPathComponent("steamcmd")
    }
}

/// Only local fixture data is approved here; this provider never invokes system security tools.
private final class ApprovalFixtureRuntime: SteamCMDRuntimeProviding, SteamCMDRuntimeApproving, @unchecked Sendable {
    private let lock = NSLock()
    private var approved: [String: Data] = [:]
    func resolve(executable: URL) throws -> SteamCMDRuntime {
        try FixtureRuntime(blocked: nil).resolve(executable: executable)
    }
    func validate(at root: URL) async throws {
        try await FixtureRuntime(blocked: nil).validate(at: root)
        try requireApproval(root)
    }
    func prepare(executable: URL, staging: URL) async throws -> URL {
        try await FixtureRuntime(blocked: nil).prepare(executable: executable, staging: staging)
    }
    func approvalCandidate(at root: URL) async throws -> SteamCMDApprovalCandidate {
        _ = try resolve(executable: root.appendingPathComponent("steamcmd"))
        try await FixtureRuntime(blocked: nil).validate(at: root)
        return SteamCMDApprovalCandidate(rootURL: root, fingerprint: try fingerprint(root))
    }
    func approve(_ candidate: SteamCMDApprovalCandidate) async throws {
        guard try fingerprint(candidate.rootURL) == candidate.fingerprint else {
            throw SteamCMDSetupIssue(kind: .invalidSelection, detail: "Changed fixture candidate")
        }
        let quarantine = try quarantine(candidate.rootURL)
        lock.withLock { approved[candidate.fingerprint] = quarantine }
    }
    private func requireApproval(_ root: URL) throws {
        let digest = try fingerprint(root)
        guard let expectedQuarantine = lock.withLock({ approved[digest] }) else {
            throw SteamCMDSetupIssue(kind: .securityApprovalRequired, detail: "Fixture policy rejection at \(root.path)")
        }
        guard try quarantine(root) == expectedQuarantine else {
            throw SteamCMDSetupIssue(kind: .fileSystem, detail: "Retry reapplied quarantine to approved fixture bytes")
        }
    }
    private func quarantine(_ root: URL) throws -> Data {
        let path = root.appendingPathComponent("steamcmd").path
        let size = getxattr(path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW)
        guard size >= 0 else { throw SteamCMDSetupIssue(kind: .fileSystem, detail: "Missing fixture quarantine") }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(path, "com.apple.quarantine", $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
        guard read == size else { throw SteamCMDSetupIssue(kind: .fileSystem, detail: "Changed fixture quarantine") }
        return data
    }
    private func fingerprint(_ root: URL) throws -> String {
        var content = Data()
        for name in ["steamcmd", "steamconsole.dylib"] {
            content.append(Data(name.utf8))
            let file = root.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: file.path) { content.append(try Data(contentsOf: file)) }
            content.append(0)
        }
        return content.base64EncodedString()
    }
}

private struct FixtureRunner: SteamCMDProcessRunning {
    enum Mode: Sendable { case complete, removeBeforePublication, waitForCancellation, waitBeforePublication, pauseAfterExtraction }
    let root: URL
    let mode: Mode
    func run(executable: URL, arguments: [String], workingDirectory: URL, environment: [String: String],
             onOutput: @escaping @Sendable (Data) -> Void) async throws -> Int32 {
        if executable.path == "/usr/bin/tar" {
            if arguments.contains("-x") { try Data().write(to: root.appendingPathComponent("extraction-started")) }
            let status = try await SteamCMDProcessRunner().run(executable: executable, arguments: arguments,
                workingDirectory: workingDirectory, environment: environment, onOutput: onOutput)
            if arguments.contains("-x"), mode == .pauseAfterExtraction {
                try Data().write(to: root.appendingPathComponent("extraction-finished"))
                // Deliberately deliver tar's successful completion after parent cancellation, so
                // the traversal handoff must propagate cancellation and await its worker itself.
                try? await Task.sleep(for: .seconds(60))
            }
            return status
        }
        try Data().write(to: root.appendingPathComponent("smoke-started"))
        let countURL = root.appendingPathComponent("smoke-count")
        let count = (try? String(contentsOf: countURL, encoding: .utf8)).flatMap(Int.init) ?? 0
        try Data(String(count + 1).utf8).write(to: countURL)
        if mode == .waitForCancellation {
            return try await SteamCMDProcessRunner().run(executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "(sleep 3; printf late > late-write) & echo $! > child-started; wait"],
                workingDirectory: root, environment: environment, onOutput: onOutput)
        }
        if mode == .removeBeforePublication {
            try FileManager.default.removeItem(at: workingDirectory.deletingLastPathComponent().appendingPathComponent("runtime"))
        }
        if mode == .waitBeforePublication { try await Task.sleep(for: .seconds(60)) }
        return 0
    }
}

/// Replays the redirect/response race synchronously from the serial delegate's progress callback.
/// The dummy task is never resumed; only the URLProtocol-backed download can deliver bytes.
private final class RejectedRedirectEvents: @unchecked Sendable {
    private let destination: URL
    private let deliversFinalResponse: Bool
    private let lock = NSLock()
    private weak var download: SteamCMDDownload?

    init(destination: URL, deliversFinalResponse: Bool) {
        self.destination = destination
        self.deliversFinalResponse = deliversFinalResponse
    }

    func attach(_ download: SteamCMDDownload) { lock.withLock { self.download = download } }

    func rejectRedirect(received: Int64) {
        guard received == 0, let download = lock.withLock({ self.download }) else { return }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: SteamCMDPackageManifest.url)
        let redirect = HTTPURLResponse(url: SteamCMDPackageManifest.url, statusCode: 302, httpVersion: "HTTP/1.1",
            headerFields: ["Location": destination.absoluteString])!
        download.urlSession(session, task: task, willPerformHTTPRedirection: redirect,
            newRequest: URLRequest(url: destination), completionHandler: { request in
                guard request == nil, self.deliversFinalResponse else { return }
                // completionHandler(nil) can turn the rejected 302 into a final response
                // before the redirect delegate gets to task.cancel().
                download.urlSession(session, dataTask: task, didReceive: redirect, completionHandler: { _ in })
            })
    }
}

private final class BootstrapURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response: Sendable { let body: Data; let status: Int; let headers: [String: String]; let hold: Bool; let redirect: URL? }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var responses: [String: [String: Response]] = [:]
    static func register(_ id: String, response: Response) {
        let bins = SteamCMDSetupTests.tar([SteamCMDSetupTests.TarEntry("bins-marker", contents: "bins")])
        let packages = [("steamcmd_osx", response.body), ("steamcmd_bins_osx", bins)]
        var manifest = "\"osx\" { \"version\" \"1788292693\"\n"
        var routes: [String: Response] = [:]
        for (name, body) in packages {
            let sha1 = Insecure.SHA1.hash(data: body).map { String(format: "%02x", $0) }.joined()
            let sha256 = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
            let file = "\(name).zip.\(sha1)"
            manifest += "\"\(name)\" { \"file\" \"\(file)\" \"size\" \"\(body.count)\" \"sha2\" \"\(sha256)\" }\n"
            routes["/client/" + file] = Response(body: body, status: response.status, headers: response.headers, hold: response.hold, redirect: response.redirect)
        }
        manifest += "}"
        routes["/client/steam_cmd_osx"] = Response(body: Data(manifest.utf8), status: 200, headers: [:], hold: false, redirect: nil)
        lock.withLock { responses[id] = routes }
    }
    static func replace(_ id: String, path: String, response: Response) {
        lock.withLock { responses[id]?[path] = response }
    }
    static func routes(_ id: String) -> [String: Response] { lock.withLock { responses[id] ?? [:] } }
    static func remove(_ id: String) { _ = lock.withLock { responses.removeValue(forKey: id) } }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "steamcdn-a.akamaihd.net" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = Self.lock.withLock { Self.responses[request.value(forHTTPHeaderField: "X-SteamCMD-Test") ?? ""]?[request.url?.path ?? ""] }
        guard let response else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        if let redirect = response.redirect {
            let redirectResponse = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": redirect.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: redirect), redirectResponse: redirectResponse)
            return
        }
        var headers = response.headers
        if headers["Content-Length"] == nil { headers["Content-Length"] = String(response.body.count) }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        if response.hold { return }
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
