import XCTest
@testable import WallpaperMachine

/// A wallpaper that refuses to render leaves the engine restoring its previous
/// configuration. The Library must stay usable so another wallpaper can be
/// applied without restarting the app.
@MainActor
final class WallpaperActivationRecoveryTests: XCTestCase {
    private var home: URL!
    private var previousHome: String?

    override func setUpWithError() throws {
        previousHome = ProcessInfo.processInfo.environment["WALLPAPER_MACHINE_HOME"]
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = home.appendingPathComponent("Library/failing", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // A complete web project passes its preflight without decoding media or
        // needing scene assets; this test covers the apply failure, not validation.
        try Data(#"{"type":"web","title":"Failing","file":"index.html"}"#.utf8)
            .write(to: folder.appendingPathComponent("project.json"))
        try Data("<!doctype html><title>Failing</title>".utf8)
            .write(to: folder.appendingPathComponent("index.html"))
        setenv("WALLPAPER_MACHINE_HOME", home.path, 1)
    }

    override func tearDownWithError() throws {
        if let previousHome { setenv("WALLPAPER_MACHINE_HOME", previousHome, 1) }
        else { unsetenv("WALLPAPER_MACHINE_HOME") }
        try FileManager.default.removeItem(at: home)
    }

    func testFailedApplyKeepsLibraryActionsAvailable() async throws {
        let bridge = ApplyFailureBridge(noPointer: .init())
        let store = BridgeStore(bridge: bridge)
        try await store.refreshAllAsync()

        await XCTAssertThrowsErrorAsync(
            try await store.activateWallpaperAsync(id: "failing", displayId: "primary"))

        XCTAssertFalse(store.activationNeedsRefresh,
                       "A recovered apply failure must not lock the Library behind a manual refresh")
        XCTAssertNil(store.activatingWallpaperID)

        // The user must be able to pick another wallpaper right away.
        bridge.applyError = nil
        try await store.activateWallpaperAsync(id: "failing", displayId: "primary")
    }

    func testUnrecoverableApplyFailureStillDemandsRefresh() async throws {
        let bridge = ApplyFailureBridge(noPointer: .init())
        let store = BridgeStore(bridge: bridge)
        try await store.refreshAllAsync()
        bridge.snapshotsFail = true

        await XCTAssertThrowsErrorAsync(
            try await store.activateWallpaperAsync(id: "failing", displayId: "primary"))

        XCTAssertTrue(store.activationNeedsRefresh,
                      "Without a trustworthy re-read the app must ask for a full refresh")
    }

    func testHistoryChangesOnlyAfterSuccessfulActivationAndPreviousFailureDoesNotConsumeIt() async throws {
        let bridge = ApplyFailureBridge(noPointer: .init())
        let history = WallpaperHistoryStore()
        let store = BridgeStore(bridge: bridge, history: history)
        try await store.refreshAllAsync()
        history.recordSwitch(from: "failing", to: "earlier", on: "primary")
        let before = history.entries
        await XCTAssertThrowsErrorAsync(try await store.activatePreviousWallpaperAsync(displayId: "primary"))
        XCTAssertEqual(history.entries, before, "a failed back operation must leave its destination available")
        bridge.applyError = nil
        try await store.activatePreviousWallpaperAsync(displayId: "primary")
        XCTAssertNil(store.previousWallpaperID(displayId: "primary"))
        XCTAssertEqual(history.recent(on: "primary", available: ["failing", "earlier"]), ["failing", "earlier"])
        let applied = history.entries
        try await store.activateWallpaperAsync(id: "failing", displayId: "primary")
        XCTAssertEqual(history.entries, applied, "reapplying must not add another history entry")
    }

    func testMatroskaVideoCanBeActivated() async throws {
        let folder = try writeVideoProject(entry: "compatibility.mkv")
        _ = try SyntheticVideoFixture.writeMatroska(name: "compatibility", into: folder)

        let (store, _) = try await videoStore()
        try await store.activateWallpaperAsync(id: "failing", displayId: "primary")

        XCTAssertEqual(store.monitorInformationSnapshot.rows.first?.wallpaperId, "failing")
        XCTAssertNil(store.activatingWallpaperID)
    }

    func testMatroskaVideoOptionsCanBeApplied() async throws {
        let folder = try writeVideoProject(entry: "compatibility.mkv")
        _ = try SyntheticVideoFixture.writeMatroska(name: "compatibility", into: folder)

        let (store, _) = try await videoStore()
        try await store.applyWallpaperOptionsAsync(wallpaperId: "failing")

        XCTAssertEqual(store.monitorInformationSnapshot.rows.first?.wallpaperId, "failing")
        XCTAssertNil(store.applyingWallpaperID)
    }

    func testIncompleteVideoEntriesCannotChangeDisplayAssignment() async throws {
        let folder = home.appendingPathComponent("Library/failing", isDirectory: true)
        try Data().write(to: folder.appendingPathComponent("empty.mkv"))
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("directory.mkv"), withIntermediateDirectories: false)

        for entry in [nil, "", "missing.mkv", "empty.mkv", "directory.mkv"] as [String?] {
            _ = try writeVideoProject(entry: entry)
            let (store, _) = try await videoStore()

            await XCTAssertThrowsErrorAsync(
                try await store.activateWallpaperAsync(id: "failing", displayId: "primary"))
            XCTAssertEqual(store.monitorInformationSnapshot.rows.first?.wallpaperId, "")
            await XCTAssertThrowsErrorAsync(
                try await store.applyWallpaperOptionsAsync(wallpaperId: "failing"))
            XCTAssertEqual(store.monitorInformationSnapshot.rows.first?.wallpaperId, "")
            XCTAssertFalse(store.activationNeedsRefresh)
            XCTAssertNil(store.activatingWallpaperID)
            XCTAssertNil(store.applyingWallpaperID)
        }
    }

    func testVideoDecoderFailurePreservesErrorAndAllowsRetry() async throws {
        for applyChanges in [false, true] {
            // A file the format check accepts (the app's own reader plays this Matroska clip) can
            // still fail in the renderer's apply: that failure is what the apply reports, and the
            // display keeps what it had.
            let folder = try writeVideoProject(entry: "compatibility.mkv")
            _ = try SyntheticVideoFixture.writeMatroska(name: "compatibility", into: folder)
            let (store, bridge) = try await videoStore()
            let decoderError = NSError(domain: "VideoDecoder", code: 23)
            bridge.applyError = decoderError

            do {
                if applyChanges {
                    try await store.applyWallpaperOptionsAsync(wallpaperId: "failing")
                } else {
                    try await store.activateWallpaperAsync(id: "failing", displayId: "primary")
                }
                XCTFail("A decoder failure must not be reported as a successful application")
            } catch {
                XCTAssertEqual((error as NSError).domain, decoderError.domain)
                XCTAssertEqual((error as NSError).code, decoderError.code)
            }
            XCTAssertEqual(store.monitorInformationSnapshot.rows.first?.wallpaperId, "")
            XCTAssertFalse(store.activationNeedsRefresh)
            XCTAssertNil(store.activatingWallpaperID)
            XCTAssertNil(store.applyingWallpaperID)

            bridge.applyError = nil
            if applyChanges {
                try await store.applyWallpaperOptionsAsync(wallpaperId: "failing")
            } else {
                try await store.activateWallpaperAsync(id: "failing", displayId: "primary")
            }
            XCTAssertEqual(store.monitorInformationSnapshot.rows.first?.wallpaperId, "failing")
        }
    }

    /// A file no player can open is refused with its format named, before any display changes,
    /// and the same file can be applied once it is replaced by one that plays.
    func testAFormatNothingCanPlayIsRefusedWithItsNameBeforeAnythingChanges() async throws {
        // The first bytes of an AVI file, which AVFoundation does not open.
        var avi = Data("RIFF".utf8)
        avi.append(contentsOf: [0x24, 0, 0, 0])
        avi.append(Data("AVI LIST".utf8))
        avi.append(Data(repeating: 0, count: 64))

        for applyChanges in [false, true] {
            let folder = try writeVideoProject(entry: "clip.avi")
            try avi.write(to: folder.appendingPathComponent("clip.avi"))
            let (store, bridge) = try await videoStore()
            bridge.applyError = nil

            do {
                if applyChanges {
                    try await store.applyWallpaperOptionsAsync(wallpaperId: "failing")
                } else {
                    try await store.activateWallpaperAsync(id: "failing", displayId: "primary")
                }
                XCTFail("an unplayable format must not be applied")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("AVI"), error.localizedDescription)
                XCTAssertTrue(
                    error.localizedDescription.localizedCaseInsensitiveContains("isn’t supported"),
                    error.localizedDescription)
            }
            XCTAssertEqual(
                store.monitorInformationSnapshot.rows.first?.wallpaperId, "",
                "the display keeps what it had")
            XCTAssertEqual(bridge.applyRequests.count, 0, "nothing reached the renderer")
            XCTAssertFalse(store.activationNeedsRefresh)
            XCTAssertNil(store.activatingWallpaperID)
            XCTAssertNil(store.applyingWallpaperID)

            // A playable copy of the same wallpaper goes through.
            _ = try writeVideoProject(entry: "compatibility.mkv")
            _ = try SyntheticVideoFixture.writeMatroska(name: "compatibility", into: folder)
            if applyChanges {
                try await store.applyWallpaperOptionsAsync(wallpaperId: "failing")
            } else {
                try await store.activateWallpaperAsync(id: "failing", displayId: "primary")
            }
            XCTAssertEqual(store.monitorInformationSnapshot.rows.first?.wallpaperId, "failing")
        }
    }

    func testAnAV1ClipOnAMacWithoutHardwareDecodeIsRefusedAndNamedAsAV1() async throws {
        let folder = try writeVideoProject(entry: "clip.mp4")
        try Data(repeating: 1, count: 64).write(to: folder.appendingPathComponent("clip.mp4"))
        let (store, bridge) = try await videoStore()
        bridge.applyError = nil
        store.videoFormatCheck = { _ in
            .unsupported(.init(container: "MP4", codec: "AV1"), .needsHardwareAV1Decode)
        }

        await XCTAssertThrowsErrorAsync(
            try await store.activateWallpaperAsync(id: "failing", displayId: "primary"))
        do {
            try await store.applyWallpaperOptionsAsync(wallpaperId: "failing")
            XCTFail("AV1 without hardware decode must not be applied")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("AV1"), error.localizedDescription)
            XCTAssertTrue(
                error.localizedDescription.localizedCaseInsensitiveContains("hardware"),
                error.localizedDescription)
        }
        XCTAssertEqual(store.monitorInformationSnapshot.rows.first?.wallpaperId, "")

        // A transient read problem says nothing about the format, so it refuses nothing.
        store.videoFormatCheck = { _ in .unreadable("the volume is busy") }
        try await store.activateWallpaperAsync(id: "failing", displayId: "primary")
        XCTAssertEqual(store.monitorInformationSnapshot.rows.first?.wallpaperId, "failing")
    }

    private func writeVideoProject(entry: String?) throws -> URL {
        let folder = home.appendingPathComponent("Library/failing", isDirectory: true)
        var manifest = ["type": "video", "title": "Video"]
        manifest["file"] = entry
        try JSONSerialization.data(withJSONObject: manifest)
            .write(to: folder.appendingPathComponent("project.json"))
        return folder
    }

    private func videoStore() async throws -> (BridgeStore, ApplyFailureBridge) {
        let bridge = ApplyFailureBridge(noPointer: .init())
        bridge.kind = .video
        bridge.applyError = nil
        let store = BridgeStore(bridge: bridge)
        try await store.refreshAllAsync()
        return (store, bridge)
    }

    func testSupportPromptWaitsForSuccessfulDownloadedActivation() async throws {
        let defaults = try TemporaryDefaults.make(for: self).defaults
        let prompt = SupportPromptStore(defaults: defaults)
        prompt.recordDownload(wallpaperID: "failing")
        let bridge = ApplyFailureBridge(noPointer: .init())
        let store = BridgeStore(bridge: bridge, supportPrompt: prompt)
        try await store.refreshAllAsync()
        XCTAssertFalse(prompt.isPending)

        await XCTAssertThrowsErrorAsync(
            try await store.activateWallpaperAsync(id: "failing", displayId: "primary", origin: .user))
        XCTAssertFalse(prompt.isPending)

        bridge.applyError = nil
        try await store.activateWallpaperAsync(id: "failing", displayId: "primary", origin: .user)
        XCTAssertTrue(prompt.isPending)
    }

    func testSupportPromptDoesNotTreatMissingDisplayAssignmentAsSuccess() async throws {
        let defaults = try TemporaryDefaults.make(for: self).defaults
        let prompt = SupportPromptStore(defaults: defaults)
        prompt.recordDownload(wallpaperID: "failing")
        let bridge = ApplyFailureBridge(noPointer: .init())
        bridge.applyError = nil
        bridge.reportsActivation = false
        let store = BridgeStore(bridge: bridge, supportPrompt: prompt)
        try await store.refreshAllAsync()

        await XCTAssertThrowsErrorAsync(
            try await store.activateWallpaperAsync(id: "failing", displayId: "primary", origin: .user))
        XCTAssertFalse(prompt.isPending)
    }

    /// The load journal holds back a wallpaper that crashed the app twice. Only the user choosing it
    /// again lifts the hold; a playlist, rule or schedule that comes round to it must not.
    func testOnlyTheUsersOwnChoiceIsMarkedAsAbleToLiftAHold() async throws {
        for userInitiated in [false, true] {
            let bridge = ApplyFailureBridge(noPointer: .init())
            bridge.applyError = nil
            let store = BridgeStore(bridge: bridge)
            try await store.refreshAllAsync()

            try await store.activateWallpaperAsync(id: "failing", displayId: "primary",
                                                   origin: userInitiated ? .user : .automation)

            XCTAssertEqual(bridge.applyRequests, [userInitiated],
                           "activation passes on who asked (userInitiated: \(userInitiated))")
        }
    }

    /// The inspector's Apply is the user choosing the wallpaper again, so on a held wallpaper it is
    /// the way back; the same settings applied for a rule or a rotation must leave the hold, and the
    /// banner that reads it, in place.
    func testApplyingAHeldWallpaperFromTheInspectorLiftsTheHoldOnlyForTheUser() async throws {
        for userInitiated in [false, true] {
            let bridge = ApplyFailureBridge(noPointer: .init())
            bridge.applyError = nil
            bridge.heldIds = ["failing"]
            let store = BridgeStore(bridge: bridge)
            try await store.refreshAllAsync()
            XCTAssertEqual(store.heldWallpaperIDs, ["failing"])

            try await store.applyWallpaperOptionsAsync(wallpaperId: "failing", userInitiated: userInitiated)

            XCTAssertEqual(store.heldWallpaperIDs, userInitiated ? [] : ["failing"],
                           "the hold after an apply (userInitiated: \(userInitiated))")
        }
    }

    /// A held wallpaper keeps its display assignment, so the display reads as showing it. Choosing
    /// it again is still how the user gets it back: that activation must reach the bridge instead
    /// of stopping at "the display already shows it".
    func testChoosingAHeldWallpaperAgainReachesTheBridgeAndLiftsTheHold() async throws {
        let bridge = ApplyFailureBridge(noPointer: .init())
        bridge.applyError = nil
        bridge.active = true
        bridge.heldIds = ["failing"]
        let store = BridgeStore(bridge: bridge)
        try await store.refreshAllAsync()
        XCTAssertTrue(store.isWallpaperActive(id: "failing", displayId: "primary"))
        XCTAssertEqual(store.heldWallpaperIDs, ["failing"])

        let result = try await store.performActivation(
            id: "failing", displayId: "primary", origin: .user, returningToPrevious: false, recordsHistory: true)

        XCTAssertEqual(result, .applied)
        XCTAssertEqual(bridge.applyRequests, [true], "the user's own choice is what lifts a hold")
        XCTAssertEqual(store.heldWallpaperIDs, [])
    }

    /// The same shortcut stays for everything else: a rotation, a rule or a layout that comes round
    /// to a held wallpaper must not reopen it, and a wallpaper that is not held is not applied again
    /// for nothing.
    func testOnlyTheUsersChoiceOpensAHeldWallpaperAndOnlyWhileItIsHeld() async throws {
        for origin in [ActivationOrigin.playlist, .automation, .layout, .updateReload] {
            let bridge = ApplyFailureBridge(noPointer: .init())
            bridge.applyError = nil
            bridge.active = true
            bridge.heldIds = ["failing"]
            let store = BridgeStore(bridge: bridge)
            try await store.refreshAllAsync()

            let result = try await store.performActivation(
                id: "failing", displayId: "primary", origin: origin, returningToPrevious: false, recordsHistory: true)

            XCTAssertEqual(result, .noOp, "\(origin)")
            XCTAssertEqual(bridge.applyRequests, [], "\(origin) must not reach the bridge")
            XCTAssertEqual(store.heldWallpaperIDs, ["failing"], "\(origin) leaves the hold alone")
        }

        let bridge = ApplyFailureBridge(noPointer: .init())
        bridge.applyError = nil
        bridge.active = true
        let store = BridgeStore(bridge: bridge)
        try await store.refreshAllAsync()
        let result = try await store.performActivation(
            id: "failing", displayId: "primary", origin: .user, returningToPrevious: false, recordsHistory: true)
        XCTAssertEqual(result, .noOp)
        XCTAssertEqual(bridge.applyRequests, [], "a wallpaper that is not held is left as it is")
    }

    func testAutomaticActivationAndNoOpReapplyDoNotRequestSupport() async throws {
        let defaults = try TemporaryDefaults.make(for: self).defaults
        let prompt = SupportPromptStore(defaults: defaults)
        prompt.recordDownload(wallpaperID: "failing")
        let bridge = ApplyFailureBridge(noPointer: .init())
        bridge.applyError = nil
        let store = BridgeStore(bridge: bridge, supportPrompt: prompt)
        try await store.refreshAllAsync()

        try await store.activateWallpaperAsync(id: "failing", displayId: "primary")
        XCTAssertFalse(prompt.isPending)
        try await store.activateWallpaperAsync(id: "failing", displayId: "primary", origin: .user)
        XCTAssertFalse(prompt.isPending)
    }

    func testApplyingAnImportedWallpaperDoesNotRequestSupport() async throws {
        let defaults = try TemporaryDefaults.make(for: self).defaults
        let prompt = SupportPromptStore(defaults: defaults)
        let bridge = ApplyFailureBridge(noPointer: .init())
        bridge.applyError = nil
        let store = BridgeStore(bridge: bridge, supportPrompt: prompt)
        try await store.refreshAllAsync()

        try await store.activateWallpaperAsync(id: "failing", displayId: "primary", origin: .user)
        XCTAssertFalse(prompt.isPending)
    }

    func testEnablingDownloadedWallpaperThroughApplyChangesRequestsSupportOnlyOnSuccess() async throws {
        let defaults = try TemporaryDefaults.make(for: self).defaults
        let prompt = SupportPromptStore(defaults: defaults)
        prompt.recordDownload(wallpaperID: "failing")
        let bridge = ApplyFailureBridge(noPointer: .init())
        let store = BridgeStore(bridge: bridge, supportPrompt: prompt)
        try await store.refreshAllAsync()

        await XCTAssertThrowsErrorAsync(
            try await store.applyWallpaperOptionsAsync(wallpaperId: "failing", userInitiated: true))
        XCTAssertFalse(prompt.isPending)
        bridge.applyError = nil
        try await store.applyWallpaperOptionsAsync(wallpaperId: "failing", userInitiated: true)
        XCTAssertTrue(prompt.isPending)
    }

    // MARK: Keeping the previous picture on screen

    /// Records what the store tells a switch hold, and what the bridge was doing between.
    private func holdEvents(of store: BridgeStore, bridge: ApplyFailureBridge) -> EventLog {
        let log = EventLog()
        store.willSwitchWallpaper = { log.events.append("will \($0)") }
        store.didSettleWallpaperSwitch = { log.events.append("settle \($0)") }
        store.didAbandonWallpaperSwitch = { log.events.append("abandon \($0)") }
        bridge.holdApply = { log.events.append("apply") }
        return log
    }

    func testASwitchIsAnnouncedBeforeTheApplyAndSettledAfterIt() async throws {
        let bridge = ApplyFailureBridge(noPointer: .init())
        bridge.applyError = nil
        bridge.monitorTitle = "Built-in (69733254 - Primary)"
        let store = BridgeStore(bridge: bridge)
        try await store.refreshAllAsync()
        let log = holdEvents(of: store, bridge: bridge)

        try await store.activateWallpaperAsync(id: "failing", displayId: "primary", origin: .user)

        XCTAssertEqual(log.events, ["will [69733254]", "apply", "settle [69733254]"])
    }

    func testAFailedApplyAbandonsTheSwitchInsteadOfSettlingIt() async throws {
        let bridge = ApplyFailureBridge(noPointer: .init())
        bridge.monitorTitle = "Built-in (69733254 - Primary)"
        let store = BridgeStore(bridge: bridge)
        try await store.refreshAllAsync()
        let log = holdEvents(of: store, bridge: bridge)

        await XCTAssertThrowsErrorAsync(
            try await store.activateWallpaperAsync(id: "failing", displayId: "primary"))

        XCTAssertEqual(log.events, ["will [69733254]", "apply", "abandon [69733254]"])
    }

    func testAnApplyThatLandedButWasNotReportedActiveStillCountsAsSettled() async throws {
        let bridge = ApplyFailureBridge(noPointer: .init())
        bridge.applyError = nil
        bridge.reportsActivation = false
        bridge.monitorTitle = "Built-in (69733254 - Primary)"
        let store = BridgeStore(bridge: bridge)
        try await store.refreshAllAsync()
        let log = holdEvents(of: store, bridge: bridge)

        await XCTAssertThrowsErrorAsync(
            try await store.activateWallpaperAsync(id: "failing", displayId: "primary"))

        XCTAssertEqual(log.events, ["will [69733254]", "apply", "settle [69733254]"],
                       "the engine applied it, so exactly one of settle and abandon fires, and it is settle")
    }

    func testActivatingTheWallpaperAlreadyShownAnnouncesNothing() async throws {
        let bridge = ApplyFailureBridge(noPointer: .init())
        bridge.applyError = nil
        bridge.monitorTitle = "Built-in (69733254 - Primary)"
        let store = BridgeStore(bridge: bridge)
        try await store.refreshAllAsync()
        try await store.activateWallpaperAsync(id: "failing", displayId: "primary")
        let log = holdEvents(of: store, bridge: bridge)

        let result = try await store.performActivation(
            id: "failing", displayId: "primary", origin: .user,
            returningToPrevious: false, recordsHistory: true)

        XCTAssertEqual(result, .noOp)
        XCTAssertEqual(log.events, [], "nothing changes, so there is no picture to hold")
    }

    func testASwitchHoldsTheDisplayAndEveryDisplayMirroringIt() {
        let store = BridgeStore(bridge: ApplyFailureBridge(noPointer: .init()))
        func row(_ id: String, _ title: String, mirroring target: String? = nil) -> BridgeMonitorInfoRow {
            BridgeMonitorInfoRow(displayId: id, title: title, wallpaperId: "failing", wallpaperTitle: "Failing",
                                 mirrorTargetDisplayId: target, mirrorTargetTitle: nil,
                                 scalingMode: "fill", targetFps: "30", audioResponse: false)
        }
        store.monitorInformationSnapshot = BridgeMonitorInformationSnapshot(rows: [
            row("1", "Left (1 - Primary)"),
            row("2", "Right (2 - Mirror)", mirroring: "1"),
            row("3", "Other (3 - Secondary)"),
            row("identity:{\"uuid\":\"A\"}", "Third (4 - Mirror)", mirroring: "1"),
            row("5", "Elsewhere (5 - Mirror)", mirroring: "3"),
        ])

        XCTAssertEqual(store.switchHoldDisplays(for: "1"), [1, 2, 4])
        XCTAssertEqual(store.switchHoldDisplays(for: "3"), [3, 5])
        XCTAssertEqual(store.switchHoldDisplays(for: "missing"), [])
    }

    func testPlaybackEnvironmentChangesDoNotInterruptApply() async throws {
        for change in PlaybackEnvironmentChange.allCases {
            for applyChanges in [false, true] {
                let bridge = ApplyFailureBridge(noPointer: .init())
                bridge.applyError = nil
                let store = BridgeStore(bridge: bridge)
                try await store.refreshAllAsync()
                let entered = expectation(description: "Apply entered")
                var release: CheckedContinuation<Void, Never>?
                bridge.holdApply = {
                    await withCheckedContinuation {
                        release = $0
                        entered.fulfill()
                    }
                }
                let activation = Task {
                    if applyChanges {
                        try await store.applyWallpaperOptionsAsync(wallpaperId: "failing")
                    } else {
                        try await store.activateWallpaperAsync(id: "failing", displayId: "primary")
                    }
                }
                await fulfillment(of: [entered], timeout: 2)
                let requested = expectation(description: "Environment change requested")
                let update = Task {
                    requested.fulfill()
                    try await change.perform(on: store)
                }
                await fulfillment(of: [requested], timeout: 2)
                XCTAssertEqual(bridge.environmentChangeCount, 0, "\(change) must wait for apply")
                release?.resume()
                try await activation.value
                try await update.value

                XCTAssertEqual(store.monitorInformationSnapshot.rows.first?.wallpaperId, "failing")
                XCTAssertEqual(store.wallpaperOptionsSnapshot?.dirty, false)
                XCTAssertEqual(bridge.environmentChangeCount, 1)
                XCTAssertFalse(store.activationNeedsRefresh)
            }
        }
    }

    func testApplyWaitsForInFlightPlaybackEnvironmentChange() async throws {
        for change in PlaybackEnvironmentChange.allCases {
            for applyChanges in [false, true] {
                let bridge = ApplyFailureBridge(noPointer: .init())
                bridge.applyError = nil
                let store = BridgeStore(bridge: bridge)
                try await store.refreshAllAsync()
                let entered = expectation(description: "Environment change entered")
                var release: CheckedContinuation<Void, Never>?
                bridge.holdEnvironmentChange = {
                    await withCheckedContinuation {
                        release = $0
                        entered.fulfill()
                    }
                }
                let update = Task { try await change.perform(on: store) }
                await fulfillment(of: [entered], timeout: 2)
                let requested = expectation(description: "Apply requested")
                let activation = Task {
                    requested.fulfill()
                    if applyChanges {
                        try await store.applyWallpaperOptionsAsync(wallpaperId: "failing")
                    } else {
                        try await store.activateWallpaperAsync(id: "failing", displayId: "primary")
                    }
                }
                await fulfillment(of: [requested], timeout: 2)
                release?.resume()
                try await update.value
                try await activation.value

                XCTAssertEqual(store.monitorInformationSnapshot.rows.first?.wallpaperId, "failing")
                XCTAssertEqual(store.wallpaperOptionsSnapshot?.dirty, false)
                XCTAssertFalse(store.activationNeedsRefresh)
            }
        }
    }

    func testFailedEnvironmentChangeReleasesWaitingActivation() async throws {
        let bridge = ApplyFailureBridge(noPointer: .init())
        bridge.applyError = nil
        bridge.environmentError = CancellationError()
        let store = BridgeStore(bridge: bridge)
        try await store.refreshAllAsync()
        let entered = expectation(description: "Environment change entered")
        var release: CheckedContinuation<Void, Never>?
        bridge.holdEnvironmentChange = {
            await withCheckedContinuation {
                release = $0
                entered.fulfill()
            }
        }
        let update = Task { try await store.refreshDisplaysAsync() }
        await fulfillment(of: [entered], timeout: 2)
        let requested = expectation(description: "Apply requested")
        let activation = Task {
            requested.fulfill()
            try await store.activateWallpaperAsync(id: "failing", displayId: "primary")
        }
        await fulfillment(of: [requested], timeout: 2)
        release?.resume()
        await XCTAssertThrowsErrorAsync(try await update.value)
        try await activation.value
        XCTAssertEqual(store.monitorInformationSnapshot.rows.first?.wallpaperId, "failing")
    }

    func testFailedApplyReleasesWaitingEnvironmentChange() async throws {
        let bridge = ApplyFailureBridge(noPointer: .init())
        let store = BridgeStore(bridge: bridge)
        try await store.refreshAllAsync()
        let entered = expectation(description: "Apply entered")
        var release: CheckedContinuation<Void, Never>?
        bridge.holdApply = {
            await withCheckedContinuation {
                release = $0
                entered.fulfill()
            }
        }
        let activation = Task { try await store.activateWallpaperAsync(id: "failing", displayId: "primary") }
        await fulfillment(of: [entered], timeout: 2)
        let requested = expectation(description: "Refresh requested")
        let update = Task {
            requested.fulfill()
            try await store.refreshDisplaysAsync()
        }
        await fulfillment(of: [requested], timeout: 2)
        release?.resume()
        await XCTAssertThrowsErrorAsync(try await activation.value)
        try await update.value
        XCTAssertEqual(bridge.environmentChangeCount, 1)
        XCTAssertFalse(store.activationNeedsRefresh)

        bridge.holdApply = nil
        bridge.applyError = nil
        try await store.activateWallpaperAsync(id: "failing", displayId: "primary")
        XCTAssertEqual(store.monitorInformationSnapshot.rows.first?.wallpaperId, "failing")
    }

    func testCancelledWaitingEnvironmentChangeDoesNotRunAfterApply() async throws {
        let bridge = ApplyFailureBridge(noPointer: .init())
        bridge.applyError = nil
        let store = BridgeStore(bridge: bridge)
        try await store.refreshAllAsync()
        let entered = expectation(description: "Apply entered")
        var release: CheckedContinuation<Void, Never>?
        bridge.holdApply = {
            await withCheckedContinuation {
                release = $0
                entered.fulfill()
            }
        }
        let activation = Task { try await store.activateWallpaperAsync(id: "failing", displayId: "primary") }
        await fulfillment(of: [entered], timeout: 2)
        let requested = expectation(description: "Mute requested")
        let update = Task {
            requested.fulfill()
            try await store.setAudioSuppressedAsync(true)
        }
        await fulfillment(of: [requested], timeout: 2)
        update.cancel()
        release?.resume()
        try await activation.value
        await XCTAssertThrowsErrorAsync(try await update.value)
        XCTAssertEqual(bridge.environmentChangeCount, 0)
        XCTAssertEqual(store.monitorInformationSnapshot.rows.first?.wallpaperId, "failing")

        try await store.setAudioSuppressedAsync(false)
        XCTAssertEqual(bridge.environmentChangeCount, 1)
    }

    func testExplicitPauseCanStillInterruptApply() async throws {
        let bridge = ApplyFailureBridge(noPointer: .init())
        bridge.applyError = nil
        let store = BridgeStore(bridge: bridge)
        try await store.refreshAllAsync()
        let entered = expectation(description: "Apply entered")
        var release: CheckedContinuation<Void, Never>?
        bridge.holdApply = {
            await withCheckedContinuation {
                release = $0
                entered.fulfill()
            }
        }
        let activation = Task { try await store.activateWallpaperAsync(id: "failing", displayId: "primary") }
        await fulfillment(of: [entered], timeout: 2)
        try await store.pauseAllAsync()
        XCTAssertEqual(store.appSnapshot.playbackState, .paused)
        release?.resume()
        await XCTAssertThrowsErrorAsync(try await activation.value)
        XCTAssertEqual(store.appSnapshot.playbackState, .paused)
        XCTAssertEqual(store.wallpaperOptionsSnapshot?.dirty, true)
        XCTAssertFalse(store.activationNeedsRefresh)
    }

    /// Only the user choosing counts as a choice: a playlist, a rule, a restored layout or an
    /// update reloading files must never tell automation the user took over a display.
    func testOnlyTheUsersOwnActivationReportsAManualChoice() async throws {
        for origin in [ActivationOrigin.user, .playlist, .automation, .layout, .updateReload] {
            let bridge = ApplyFailureBridge(noPointer: .init())
            bridge.applyError = nil
            let store = BridgeStore(bridge: bridge)
            try await store.refreshAllAsync()
            var chosen: [String] = []
            store.onUserWallpaperChoice = { id, display in chosen.append("\(display)=\(id)") }

            try await store.activateWallpaperAsync(id: "failing", displayId: "primary", origin: origin)
            XCTAssertEqual(chosen, origin.isUserChoice ? ["primary=failing"] : [], "\(origin)")

            // Asking again for what the display already shows changes nothing, and is still the
            // user's choice only when the user asked.
            try await store.activateWallpaperAsync(id: "failing", displayId: "primary", origin: origin)
            XCTAssertEqual(chosen, origin.isUserChoice ? ["primary=failing", "primary=failing"] : [], "\(origin)")
        }
    }

    func testUpdateReloadLoadsTheWallpaperAgainOnTheDisplayShowingIt() async throws {
        let bridge = ApplyFailureBridge(noPointer: .init())
        bridge.applyError = nil
        let store = BridgeStore(bridge: bridge)
        try await store.refreshAllAsync()
        try await store.activateWallpaperAsync(id: "failing", displayId: "primary", origin: .user)
        var chosen = 0
        store.onUserWallpaperChoice = { _, _ in chosen += 1 }

        try await store.reloadWallpaperAsync(id: "failing")

        XCTAssertEqual(bridge.ejects, 1)
        XCTAssertTrue(store.isWallpaperActive(id: "failing", displayId: "primary"))
        XCTAssertEqual(chosen, 0, "Reloading files is not the user choosing a wallpaper")
    }

    func testUpdateReloadGivesWayToAChoiceTheUserIsWaitingOn() async throws {
        let bridge = ApplyFailureBridge(noPointer: .init())
        bridge.applyError = nil
        let store = BridgeStore(bridge: bridge)
        try await store.refreshAllAsync()
        try await store.activateWallpaperAsync(id: "failing", displayId: "primary", origin: .user)
        let slot = BridgeStore.activationSlot(displayId: "primary")
        var release: CheckedContinuation<Void, Never>?
        let blocker = Task { await store.commands.run { await withCheckedContinuation { release = $0 } } }
        for _ in 0..<1_000 where release == nil { await Task.yield() }
        var chosen = false
        let choice = Task { await store.commands.run(slot: slot, subject: "other") { chosen = true } }
        for _ in 0..<1_000 where !store.commands.hasWaiting(slot: slot) { await Task.yield() }
        XCTAssertTrue(store.commands.hasWaiting(slot: slot))

        try await store.reloadWallpaperAsync(id: "failing")
        XCTAssertEqual(bridge.ejects, 0, "A reload must not take the display away while the user's choice waits")

        release?.resume()
        await blocker.value
        let ran = await choice.value
        XCTAssertTrue(ran)
        XCTAssertTrue(chosen)
        XCTAssertEqual(bridge.ejects, 0)
        XCTAssertTrue(store.isWallpaperActive(id: "failing", displayId: "primary"))
    }

    /// Downloads and imports rescan the library on their own schedule; one landing mid-apply
    /// waits for the apply instead of failing with a "wait" error.
    func testLibraryRefreshDuringApplyWaitsForIt() async throws {
        let bridge = ApplyFailureBridge(noPointer: .init())
        bridge.applyError = nil
        let store = BridgeStore(bridge: bridge)
        try await store.refreshAllAsync()
        var release: CheckedContinuation<Void, Never>?
        bridge.holdApply = { await withCheckedContinuation { release = $0 } }

        let activation = Task { try await store.activateWallpaperAsync(id: "failing", displayId: "primary") }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while release == nil && ContinuousClock.now < deadline { await Task.yield() }
        guard let release else {
            activation.cancel()
            XCTFail("The apply operation did not reach its suspension point")
            return
        }
        let refresh = Task { try await store.refreshLibraryAsync() }
        for _ in 0..<50 { await Task.yield() }
        XCTAssertNil(bridge.refreshSawActive, "The rescan must not start while the apply is in flight")

        release.resume()
        try await activation.value
        try await refresh.value
        XCTAssertEqual(bridge.refreshSawActive, true)
    }

    // MARK: Retry for a scene that stopped drawing

    /// Applying a wallpaper that a display already shows changes nothing, so a stopped scene
    /// is brought back by taking the wallpaper off the display and applying it again.
    func testRetryReloadsOnlyTheNamedDisplayThroughItsSlot() async throws {
        let (store, bridge) = try await twoDisplayStore(showing: ["primary": "a", "secondary": "a"])
        let revision = store.wallpaperContentRevision

        try await store.retryStoppedSceneAsync(displayId: "primary")

        XCTAssertEqual(
            bridge.events, ["eject primary a", "apply primary a"],
            "The wallpaper leaves the display and is applied to it again, and the other display is not touched")
        XCTAssertEqual(bridge.assignments, ["primary": "a", "secondary": "a"])
        XCTAssertEqual(
            store.wallpaperContentRevision, revision,
            "A retry loads the same files again, so the posters made from them are not stale")
        XCTAssertFalse(store.commands.isBusy)
        XCTAssertNil(store.activatingWallpaperID)
    }

    /// A mirror presents a scene of its own, but its wallpaper is its source's: nothing can be
    /// ejected from the mirror, so Retry reloads the display it mirrors.
    func testRetryOnAMirroringDisplayReloadsTheDisplayItMirrors() async throws {
        let (store, bridge) = try await twoDisplayStore(showing: ["primary": "a"], mirroring: ["secondary": "primary"])
        let revision = store.wallpaperContentRevision

        try await store.retryStoppedSceneAsync(displayId: "secondary")

        XCTAssertEqual(
            bridge.events, ["eject primary a", "apply primary a"],
            "The wallpaper is taken off and applied to the display it mirrors, and never ejected from the mirror")
        XCTAssertEqual(bridge.assignments, ["primary": "a"])
        XCTAssertEqual(store.wallpaperContentRevision, revision)
        XCTAssertFalse(store.commands.isBusy)
    }

    func testRetryOnAMirrorWhoseSourceShowsNothingThrowsAUsefulError() async throws {
        let (store, bridge) = try await twoDisplayStore(showing: [:], mirroring: ["secondary": "primary"])

        do {
            try await store.retryStoppedSceneAsync(displayId: "secondary")
            XCTFail("A mirror of an empty display has nothing to reload")
        } catch {
            XCTAssertEqual(
                error.localizedDescription, String(localized: "No wallpaper is running on this display."))
        }
        XCTAssertEqual(bridge.events, [])
    }

    func testRetryOnADisplayWithNoWallpaperThrowsAUsefulError() async throws {
        let (store, bridge) = try await twoDisplayStore(showing: ["primary": "a"])

        for display in ["secondary", "elsewhere"] {
            do {
                try await store.retryStoppedSceneAsync(displayId: display)
                XCTFail("There is nothing to reload on \(display)")
            } catch {
                XCTAssertEqual(
                    error.localizedDescription, String(localized: "No wallpaper is running on this display."))
            }
        }
        XCTAssertEqual(bridge.events, [], "Nothing is ejected from or applied to a display that shows nothing")
        XCTAssertEqual(bridge.assignments, ["primary": "a"])
    }

    /// The reload an update asks for, with no display named, still covers every display.
    func testReloadingAWallpaperEverywhereReloadsEveryDisplayShowingItAndMarksItsFilesChanged() async throws {
        let (store, bridge) = try await twoDisplayStore(showing: ["primary": "a", "secondary": "a"])
        let revision = store.wallpaperContentRevision

        try await store.reloadWallpaperAsync(id: "a")

        XCTAssertEqual(
            bridge.events,
            ["eject primary a", "apply primary a", "eject secondary a", "apply secondary a"])
        XCTAssertEqual(bridge.assignments, ["primary": "a", "secondary": "a"])
        XCTAssertEqual(
            store.wallpaperContentRevision, revision &+ 1,
            "An update replaced the files, which is what the posters are rebuilt for")
    }

    /// A reload that waited behind a command that switches its display must not put the old
    /// wallpaper back.
    func testARetryThatWaitedBehindASwitchOnItsDisplayLeavesTheSwitchAlone() async throws {
        let (store, bridge) = try await twoDisplayStore(showing: ["primary": "a", "secondary": "b"])
        let slot = BridgeStore.activationSlot(displayId: "primary")
        var release: CheckedContinuation<Void, Never>?
        bridge.beforeApply = {
            bridge.beforeApply = nil
            await withCheckedContinuation { release = $0 }
        }
        // No slot of its own, as a layout has: the retry waits for it instead of giving way.
        let switching = Task {
            try await store.commands.run {
                try await store.activateWallpaperAsync(id: "c", displayId: "primary", origin: .user)
            }
        }
        let held = ContinuousClock.now.advanced(by: .seconds(5))
        while release == nil && ContinuousClock.now < held { await Task.yield() }
        guard let release else {
            switching.cancel()
            return XCTFail("The switch did not reach the bridge")
        }

        let retry = Task { try await store.retryStoppedSceneAsync(displayId: "primary") }
        let queued = ContinuousClock.now.advanced(by: .seconds(5))
        while !store.commands.hasWaiting(slot: slot) && ContinuousClock.now < queued { await Task.yield() }
        XCTAssertTrue(store.commands.hasWaiting(slot: slot), "The retry waits its turn behind the switch")

        release.resume()
        try await switching.value
        try await retry.value

        XCTAssertEqual(bridge.assignments, ["primary": "c", "secondary": "b"])
        XCTAssertEqual(
            bridge.events, ["apply primary c"],
            "The retry found the display showing another wallpaper and reloaded nothing")
    }

    /// A retry that arrives while the user's own switch is running on its display does not queue up
    /// behind it: it gives way at once, as it does to a switch that waits.
    func testARetryGivesWayToASwitchRunningOnItsDisplay() async throws {
        let (store, bridge) = try await twoDisplayStore(showing: ["primary": "a", "secondary": "b"])
        let slot = BridgeStore.activationSlot(displayId: "primary")
        var release: CheckedContinuation<Void, Never>?
        bridge.beforeApply = {
            bridge.beforeApply = nil
            await withCheckedContinuation { release = $0 }
        }
        let switching = Task {
            try await store.commands.run(slot: slot) {
                try await store.activateWallpaperAsync(id: "c", displayId: "primary", origin: .user)
            }
        }
        let held = ContinuousClock.now.advanced(by: .seconds(5))
        while release == nil && ContinuousClock.now < held { await Task.yield() }
        guard let release else {
            switching.cancel()
            return XCTFail("The switch did not reach the bridge")
        }

        try await store.retryStoppedSceneAsync(displayId: "primary")
        XCTAssertFalse(store.commands.hasWaiting(slot: slot), "The retry does not wait behind the switch")

        release.resume()
        try await switching.value

        XCTAssertEqual(bridge.assignments, ["primary": "c", "secondary": "b"])
        XCTAssertEqual(bridge.events, ["apply primary c"], "The retry reloaded nothing")
    }

    /// The same slot as a switch: a choice made while a retry still waits replaces it.
    func testANewerChoiceOnTheDisplayReplacesARetryStillWaiting() async throws {
        let (store, bridge) = try await twoDisplayStore(showing: ["primary": "a", "secondary": "b"])
        let slot = BridgeStore.activationSlot(displayId: "primary")
        var gate: CheckedContinuation<Void, Never>?
        let holder = Task { await store.commands.run { await withCheckedContinuation { gate = $0 } } }
        let held = ContinuousClock.now.advanced(by: .seconds(5))
        while gate == nil && ContinuousClock.now < held { await Task.yield() }
        guard let gate else {
            holder.cancel()
            return XCTFail("The first command did not start")
        }

        let retry = Task { try await store.retryStoppedSceneAsync(displayId: "primary") }
        let queued = ContinuousClock.now.advanced(by: .seconds(5))
        while !store.commands.hasWaiting(slot: slot) && ContinuousClock.now < queued { await Task.yield() }
        XCTAssertTrue(store.commands.hasWaiting(slot: slot), "The retry waits behind the running command")

        let choice = Task {
            try await store.commands.run(slot: slot) {
                try await store.activateWallpaperAsync(id: "c", displayId: "primary", origin: .user)
            }
        }
        // The queue answers the replaced retry at once, while the first command still runs.
        try await retry.value
        XCTAssertEqual(bridge.events, [], "The replaced retry did not run")

        gate.resume()
        _ = await holder.value
        try await choice.value
        XCTAssertEqual(bridge.events, ["apply primary c"])
        XCTAssertEqual(bridge.assignments, ["primary": "c", "secondary": "b"])
    }

    private func twoDisplayStore(
        showing assignments: [String: String], mirroring mirrors: [String: String] = [:]
    ) async throws -> (BridgeStore, DisplayTransferTestBridge) {
        let bridge = DisplayTransferTestBridge(noPointer: .init())
        bridge.assignments = assignments
        bridge.mirrors = mirrors
        try bridge.installProjects(in: home.appendingPathComponent("Library", isDirectory: true))
        let store = BridgeStore(bridge: bridge)
        try await store.refreshAllAsync()
        return (store, bridge)
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @autoclosure () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {}
}

private enum PlaybackEnvironmentChange: CaseIterable {
    case displays, suspend, resume, suspendDisplay, resumeDisplay, unload, reload, mute, unmute
    case qualityThrottle

    @MainActor
    func perform(on store: BridgeStore) async throws {
        switch self {
        case .displays: try await store.refreshDisplaysAsync()
        case .suspend: try await store.setPresentationSuspendedAsync(true)
        case .resume: try await store.setPresentationSuspendedAsync(false)
        case .suspendDisplay: try await store.setDisplayPresentationSuspendedAsync(displayID: 7, suspended: true)
        case .resumeDisplay: try await store.setDisplayPresentationSuspendedAsync(displayID: 7, suspended: false)
        case .unload: try await store.setPresentationUnloadedAsync(true)
        case .reload: try await store.setPresentationUnloadedAsync(false)
        case .mute: try await store.setAudioSuppressedAsync(true)
        case .unmute: try await store.setAudioSuppressedAsync(false)
        case .qualityThrottle: try await store.setQualityThrottleAsync([.heat])
        }
    }
}

/// Lines a test collects from closures it hands the store.
@MainActor
private final class EventLog {
    var events: [String] = []
}

private final class ApplyFailureBridge: WallpaperBridge {
    var applyError: Error? = WallpaperActionError(
        message: "The wallpaper did not render a first frame within 90 seconds.")
    var snapshotsFail = false
    var kind: BridgeWallpaperKind = .projectScene
    var reportsActivation = true
    /// The display's title; the number in its `(id - Role)` suffix is its live display id.
    var monitorTitle = "Primary"
    var holdApply: (@MainActor () async -> Void)?
    var holdEnvironmentChange: (@MainActor () async -> Void)?
    var environmentError: Error?
    private(set) var environmentChangeCount = 0
    private var environmentChangeInFlight = false
    private var generation = 0
    private var dirty = false
    private var playbackState: BridgePlaybackState = .playing

    // Like the engine, a concurrent mutation invalidates the apply. Capture the
    // refresh snapshot before yielding so tests also catch late stale publication.
    @MainActor
    private func changeEnvironment() async throws -> BridgeSnapshotBundle {
        environmentChangeCount += 1
        generation += 1
        environmentChangeInFlight = true
        defer { environmentChangeInFlight = false }
        let snapshot = bundle
        if let holdEnvironmentChange { await holdEnvironmentChange() }
        if let environmentError { throw environmentError }
        return snapshot
    }

    override func refreshDisplays() async throws -> BridgeSnapshotBundle {
        try await changeEnvironment()
    }

    override func setPresentationSuspended(suspended: Bool) async throws {
        _ = try await changeEnvironment()
    }

    override func setDisplayPresentationSuspended(displayId: String, suspended: Bool) async throws {
        _ = try await changeEnvironment()
    }

    override func setPresentationUnloaded(unloaded: Bool) async throws -> BridgeSnapshotBundle {
        try await changeEnvironment()
    }

    override func setAudioSuppressed(suppressed: Bool) async throws -> BridgeSnapshotBundle {
        try await changeEnvironment()
    }

    override func setQualityThrottle(causes: [BridgeQualityThrottleCause]) async throws -> BridgeSnapshotBundle {
        try await changeEnvironment()
    }

    override func pauseAll() async throws -> BridgeSnapshotBundle {
        generation += 1
        playbackState = .paused
        return bundle
    }

    /// Whether the wallpaper was already active when the library rescan reached the bridge.
    var refreshSawActive: Bool?
    private(set) var ejects = 0

    override func ejectWallpaperFromDisplay(displayId: String, wallpaperId: String) async throws -> BridgeDisplayMutationBundle {
        ejects += 1
        active = false
        return BridgeDisplayMutationBundle(app: app, library: library, monitorInformation: monitors, settings: settings)
    }

    override func refreshLibrary() async throws -> BridgeSnapshotBundle {
        refreshSawActive = active
        return bundle
    }

    override func allSnapshots() async throws -> BridgeSnapshotBundle {
        if snapshotsFail { throw CancellationError() }
        return bundle
    }

    override func selectWallpaper(id: String) async throws -> BridgeSnapshotBundle { bundle }

    override func setDisplayConfigEnabled(
        wallpaperId: String,
        displayId: String,
        enabled: Bool
    ) async throws -> BridgeWallpaperMutationBundle {
        mutation
    }

    override func wallpaperOptionsSnapshot(
        wallpaperId: String
    ) async throws -> BridgeWallpaperOptionsSnapshot {
        options
    }

    /// Whether each apply the bridge received came from the user's own choice.
    private(set) var applyRequests: [Bool] = []

    override func applyWallpaperOptions(
        wallpaperId: String,
        userInitiated: Bool
    ) async throws -> BridgeWallpaperMutationBundle {
        applyRequests.append(userInitiated)
        let startedGeneration = generation
        let overlappedEnvironmentChange = environmentChangeInFlight
        if let holdApply { await holdApply() }
        if let applyError { throw applyError }
        // Like the engine: only the user applying a held wallpaper lifts its hold.
        if userInitiated { heldIds.removeAll { $0 == wallpaperId } }
        dirty = overlappedEnvironmentChange || generation != startedGeneration
        if !dirty { active = reportsActivation }
        return mutation
    }

    /// Mirrors the engine: the wallpaper only becomes active once an apply succeeds. A test sets it
    /// to start with the wallpaper already assigned to the display.
    var active = false
    /// Wallpapers the load journal holds back; the display keeps its assignment to them.
    var heldIds: [String] = []

    var bundle: BridgeSnapshotBundle {
        BridgeSnapshotBundle(app: app, library: library, wallpaperOptions: options,
                             monitorInformation: monitors, settings: settings)
    }

    private var mutation: BridgeWallpaperMutationBundle {
        BridgeWallpaperMutationBundle(app: app, library: library,
                                      wallpaperOptions: options,
                                      monitorInformation: monitors, settings: settings)
    }

    private var monitors: BridgeMonitorInformationSnapshot {
        BridgeMonitorInformationSnapshot(rows: [BridgeMonitorInfoRow(
            displayId: "primary", title: monitorTitle,
            wallpaperId: active ? "failing" : "", wallpaperTitle: active ? "Failing" : "",
            mirrorTargetDisplayId: nil, mirrorTargetTitle: nil,
            scalingMode: "fill", targetFps: "30", audioResponse: false
        )])
    }

    private var app: BridgeAppSnapshot {
        BridgeAppSnapshot(
            playbackState: playbackState, selectedWallpaperId: "failing",
            activeWallpaperIds: active ? ["failing"] : [], errors: [], heldWallpaperIds: heldIds)
    }

    private var library: BridgeLibrarySnapshot {
        BridgeLibrarySnapshot(
            wallpapers: [BridgeWallpaperEntry(id: "failing", title: "Failing", kind: kind,
                                              supported: true, active: false, selected: true,
                                              previewPath: nil)],
            scanStatus: BridgeLibraryScanStatus(scanning: false, done: 1, total: 1),
            sceneCount: kind == .projectScene ? 1 : 0, videoCount: kind == .video ? 1 : 0,
            webpageCount: 0, unknownCount: 0)
    }

    private var options: BridgeWallpaperOptionsSnapshot {
        BridgeSnapshotFixtures.options(
            wallpaperId: "failing", title: "Failing", kind: kind, dirty: dirty,
            displayConfigurations: [BridgeDisplayConfigRow(
                displayId: "primary", title: "Primary", enabled: false, scalingMode: .fill,
                scalingFactor: 1, framing: .centered, targetFps: 30, maxFps: 60, muted: false,
                volume: 1, dirty: false, canRestoreDefaults: false)],
            audioResponseEnabled: false)
    }

    private var settings: BridgeSettingsSnapshot {
        BridgeSnapshotFixtures.settings(
            displays: [BridgeDisplaySettingsRow(
                displayId: "primary", title: "Primary", enabled: true, mode: .standalone,
                mirrorTargets: [], selectedMirrorTarget: nil, scalingMode: .fill, scalingFactor: 1,
                targetFps: 30, maxFps: 60, muted: false, volume: 1)])
    }
}
