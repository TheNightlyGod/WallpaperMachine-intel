import Foundation
import Observation

enum LibraryLoadState: Equatable {
    case loading, loaded, failed(String)
}

struct WallpaperActionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
@Observable
final class BridgeStore {
    let bridge: WallpaperBridge
    let supportPrompt: SupportPromptStore?
    let history: WallpaperHistoryStore
    var appSnapshot: BridgeAppSnapshot
    var librarySnapshot: BridgeLibrarySnapshot {
        didSet { if librarySnapshot != oldValue { libraryPresentationRevision &+= 1 } }
    }
    var wallpaperOptionsSnapshot: BridgeWallpaperOptionsSnapshot?
    var monitorInformationSnapshot: BridgeMonitorInformationSnapshot {
        didSet { if monitorInformationSnapshot != oldValue { libraryPresentationRevision &+= 1 } }
    }
    private(set) var libraryPresentationRevision: UInt64 = 0
    var settingsSnapshot: BridgeSettingsSnapshot
    var snapshotRevision: UInt64
    var latestBridgeErrorMessage: String?
    var latestBridgeErrorRevision: UInt64
    var lockScreenWallpaper: LockScreenWallpaperService?
    @ObservationIgnored var onSnapshotApplied: (() -> Void)?
    @ObservationIgnored var onWallpaperApplied: (@MainActor (_ wallpaperID: String, _ displayID: String) -> Void)?
    @ObservationIgnored var onUserWallpaperChoice: (@MainActor (_ wallpaperID: String, _ displayID: String) -> Void)?
    /// The user took a wallpaper off a display, and the display is empty now. Not called for the
    /// ejects the app makes on its own (deleting a wallpaper, reloading or reapplying one, a
    /// display layout's recovery, a Focus restore), which the user did not ask for.
    @ObservationIgnored var onUserWallpaperRemoved: (@MainActor (_ wallpaperID: String, _ displayID: String) -> Void)?
    @ObservationIgnored var openPreview: (@MainActor (WallpaperPreviewSession.Selection) -> Void)?
    /// A wallpaper's pending property edits changed: an edit, a restored default, a revert, an
    /// apply or a preset. It runs once the change is stored and names the wallpaper, so whatever
    /// shows a copy of the draft (the preview window) can follow it.
    @ObservationIgnored var onPropertyDraftChanged: (@MainActor (_ wallpaperID: String) -> Void)?
    /// A slider or colour of the wallpaper is being dragged to a value nobody saved yet. Runs for
    /// every step the panel sends, so whatever shows the pending properties can follow the drag
    /// without waiting for it to stop; the drag ends in an edit, which runs the callback above.
    @ObservationIgnored var onPropertyDragged: (@MainActor (_ wallpaperID: String) -> Void)?
    /// Whether the displays follow a wallpaper's pending property edits while they are made
    /// (`LivePropertyEditing`). Read at every edit, so turning the switch off or on takes effect
    /// with the next one. The app supplies the stored choice; a store built without one, as in a
    /// test, never touches a display.
    @ObservationIgnored var showsPropertyEditsOnDesktop: @MainActor () -> Bool = { false }
    /// Waits out a burst of edits, a drag or a preset, so the displays get one update for it.
    @ObservationIgnored var desktopPropertyPreviews = PropertyPreviewScheduler()
    /// Where a refused desktop update goes: the app's log, never an alert, because an edit in
    /// progress must not be interrupted by it. A test collects the lines instead.
    @ObservationIgnored var desktopPropertyPreviewLog: @MainActor (String) -> Void = { AppLog.warn($0) }
    /// Wallpapers whose displays may be showing edits nobody applied, so that switching the
    /// choice off can put the saved look back. Revert and Apply do that themselves. A wallpaper
    /// leaving the set is a wallpaper whose displays draw the saved look again.
    @ObservationIgnored private var propertyEditsOnDesktop = Set<String>() {
        didSet { if !oldValue.isSubset(of: propertyEditsOnDesktop) { onPropertyEditsOnDesktopEnded?() } }
    }
    /// Runs when a wallpaper's displays are no longer shown its pending edits (Revert, turning the
    /// choice off, Apply, deleting the wallpaper), so whatever withholds a picture of the desktop
    /// while they show an edit (`isShowingPropertyEdits`) can take it again.
    @ObservationIgnored var onPropertyEditsOnDesktopEnded: (@MainActor () -> Void)?
    /// The refusal last logged for each wallpaper whose displays could not follow an edit, so a drag
    /// that keeps being refused is logged once rather than for every step.
    @ObservationIgnored private var desktopPreviewProblems: [String: String] = [:]
    /// Runs after a wallpaper was moved on a display and the move is saved, so whatever
    /// shows a picture of the desktop can retake it. Not run when the bridge refused the move.
    @ObservationIgnored var onDisplayFramingChanged: (@MainActor (_ wallpaperID: String, _ displayID: String) -> Void)?
    private(set) var hostWallpaperStates: [String: HostWallpaperState] = [:]
    @ObservationIgnored private var hostStartupTask: Task<Void, Never>?
    @ObservationIgnored var retryHostWallpaper: (@MainActor (String, UInt32) -> Void)?
    @ObservationIgnored var invalidateHostAsset: (@MainActor (String, String) -> Void)?
    /// Reads live web-wallpaper delivery state from whoever owns the web host.
    /// A closure rather than a reference because the host belongs to the app
    /// delegate and outlives no snapshot; nil while no host is running, which
    /// the panel reports as unknown rather than as "nothing is being
    /// delivered".
    @ObservationIgnored var webWallpaperDeliveryStatus: (@MainActor () -> WebWallpaperHost.DeliveryStatus)?
    var webWallpaperDeliveryRevision: UInt64 = 0
    @ObservationIgnored var sceneMediaAvailability: (@MainActor () -> SystemMediaAvailability)?
    /// Per-wallpaper energy ratings, owned by the app delegate's background recorder.
    @ObservationIgnored var wallpaperEnergyRatings: WallpaperEnergyRatings?
    let editorState = WallpaperEditorState()
    /// The user's commands, from the control panel and the menu bar, run through here.
    let commands = UserCommandQueue()
    /// A wallpaper switch keeps the picture it replaces on screen until the successor has drawn
    /// ([WallpaperSwitchHold]). The ids are the live CoreGraphics ids of the displays the switch
    /// changes, mirrors included. `willSwitch` runs before the apply and may take a moment (it
    /// asks the visible wallpaper for a still); exactly one of `didSettle` and `didAbandon`
    /// follows, `didSettle` once the engine has applied the wallpaper and `didAbandon` when the
    /// apply failed or was cancelled.
    @ObservationIgnored var willSwitchWallpaper: (@MainActor ([UInt32]) async -> Void)?
    @ObservationIgnored var didSettleWallpaperSwitch: (@MainActor ([UInt32]) -> Void)?
    @ObservationIgnored var didAbandonWallpaperSwitch: (@MainActor ([UInt32]) -> Void)?
    /// Reads a video file's format when it is about to be applied, so one nothing can play is
    /// refused with its format named before any display changes. A test stands in for the file read.
    @ObservationIgnored var videoFormatCheck: @Sendable (URL) async -> VideoFormatSupport.Verdict = {
        await VideoFormatSupport.inspect(url: $0)
    }
    /// Where the activation lines go: the app's log. A test collects them instead.
    @ObservationIgnored var activationLogWriter: (_ line: String, _ isFailure: Bool) -> Void = ActivationLog.write
    /// Performance data, when the user has turned it on (`TelemetryService`). Each activation
    /// is handed to it as the same facts its log line states.
    @ObservationIgnored var telemetry: TelemetryService?
    private(set) var activatingWallpaperID: String?
    private(set) var applyingWallpaperID: String?
    @ObservationIgnored private var activationWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var updatingPlaybackEnvironment = false
    private var activeWallpaperEdits: [String: Int] = [:]
    private var wallpaperAppliesNeedingSave = Set<String>()
    private(set) var activationNeedsRefresh = false
    private(set) var libraryLoadState: LibraryLoadState = .loading
    /// Counts library rescans (imports, downloads, the Refresh button). Unlike
    /// `snapshotRevision` it does not move with playback, so anything derived from the
    /// library's files (folder sizes, dates) can re-check only when a rescan happened.
    private(set) var libraryRefreshRevision: UInt64 = 0
    var wallpaperContentRevision: UInt64 = 0

    convenience init() throws {
        self.init(bridge: try WallpaperBridge(), supportPrompt: SupportPromptStore(),
                  history: WallpaperHistoryStore(defaults: ClientPreferences.defaults))
    }

    init(bridge: WallpaperBridge, supportPrompt: SupportPromptStore? = nil,
         history: WallpaperHistoryStore? = nil) {
        let snapshots = Self.emptySnapshots()

        self.bridge = bridge
        self.supportPrompt = supportPrompt
        self.history = history ?? WallpaperHistoryStore()
        self.appSnapshot = snapshots.app
        self.librarySnapshot = snapshots.library
        self.wallpaperOptionsSnapshot = snapshots.wallpaperOptions
        self.monitorInformationSnapshot = snapshots.monitorInformation
        self.settingsSnapshot = snapshots.settings
        self.snapshotRevision = 0
        self.latestBridgeErrorMessage = nil
        self.latestBridgeErrorRevision = 0
    }

    func refreshAllAsync() async throws {
        await waitForIdleActivation()
        do {
            let bundle = try await (activationNeedsRefresh ? bridge.refreshDisplays() : bridge.allSnapshots())
            apply(bundle)
            libraryLoadState = .loaded
            activationNeedsRefresh = false
        } catch {
            libraryLoadState = .failed(error.localizedDescription)
            throw error
        }
    }

    func bootstrapAsync() async throws {
        libraryLoadState = .loading
        do {
            let bundle = try await bridge.bootstrap()
            apply(bundle)
            libraryLoadState = .loaded
        } catch {
            libraryLoadState = .failed(error.localizedDescription)
            throw error
        }
    }

    func refreshLibraryAsync() async throws {
        await waitForIdleActivation()
        do {
            let bundle = try await bridge.refreshLibrary()
            apply(bundle)
            libraryLoadState = .loaded
            libraryRefreshRevision &+= 1
            wallpaperContentRevision &+= 1
        } catch {
            libraryLoadState = .failed(error.localizedDescription)
            throw error
        }
    }

    func deleteWallpaperAsync(id: String) async throws {
        let report = try await deleteWallpapersAsync(ids: [id])
        if let failure = report.failures.first { throw failure.error }
    }

    /// Trashes each wallpaper independently so one failure never blocks the rest;
    /// the library refreshes once after the whole batch.
    func deleteWallpapersAsync(
        ids: [String],
        recycle: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) async throws -> WallpaperDeletionReport {
        var report = WallpaperDeletionReport()
        for id in ids {
            do {
                _ = try WallpaperDeletionService.wallpaperURL(id: id, library: ClientPaths.libraryURL)
                let displayIDs = Set(monitorInformationSnapshot.rows.filter {
                    $0.wallpaperId == id && $0.mirrorTargetDisplayId == nil
                }.map(\.displayId))
                for displayID in displayIDs.sorted() {
                    try await ejectWallpaperFromDisplayAsync(displayId: displayID, wallpaperId: id)
                }
                try WallpaperDeletionService.moveToTrash(id: id, library: ClientPaths.libraryURL, recycle: recycle)
                supportPrompt?.forgetDownload(wallpaperID: id)
                report.deleted.append(id)
            } catch {
                report.failures.append((id: id, error: error))
            }
        }
        guard !report.deleted.isEmpty else { return report }
        try await refreshLibraryAsync()
        for id in report.deleted {
            editorState.discard(wallpaperID: id)
            // Nothing draws it any more, so nothing is left to take back.
            desktopPropertyPreviews.cancel(id)
            forgetPropertyEditsOnDesktop(id)
        }
        return report
    }

    func refreshDisplaysAsync() async throws {
        try await updatePlaybackEnvironment {
            let bundle = try await bridge.refreshDisplays()
            apply(bundle)
        }
    }

    /// Wallpapers a display is assigned to that the load journal left out of this session
    /// because the app died while opening them twice in a row.
    var heldWallpaperIDs: [String] { appSnapshot.heldWallpaperIds }

    /// Opens a held wallpaper again at the user's request. The reply shows it as opened and no
    /// longer held; a failure leaves the hold in place and reaches the caller.
    func releaseHeldWallpaperAsync(id: String) async throws {
        try await updatePlaybackEnvironment {
            let bundle = try await bridge.releaseHeldWallpaper(wallpaperId: id)
            apply(bundle)
        }
    }

    func receiveHostState(_ state: HostWallpaperState) {
        let previousState = hostWallpaperStates[state.key]
        if let previousState {
            guard state.startupRevision >= previousState.startupRevision else { return }
            if state.phase != .loading,
               state.startupRevision == previousState.startupRevision,
               (state.wallpaperID != previousState.wallpaperID || state.nativeAdmissionKey != previousState.nativeAdmissionKey) {
                return
            }
        }
        if state.phase == .closed {
            guard let previousState, previousState.wallpaperID == state.wallpaperID,
                  previousState.startupRevision == state.startupRevision,
                  previousState.nativeAdmissionKey == state.nativeAdmissionKey else { return }
            hostWallpaperStates.removeValue(forKey: state.key)
        }
        else { hostWallpaperStates[state.key] = state }
        guard state.phase == .ready || state.phase == .failed else { return }
        let previous = hostStartupTask
        hostStartupTask = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, self.hostWallpaperStates[state.key] == state else { return }
            do {
                let bundle = try await self.bridge.reportHostWallpaperStartup(
                    displayId: state.displayID, wallpaperId: state.wallpaperID,
                    startupRevision: state.startupRevision, nativeAdmissionKey: state.nativeAdmissionKey,
                    ready: state.phase == .ready)
                self.apply(bundle)
            } catch {
                AppLog.error("Host wallpaper startup could not be reported: \(error.localizedDescription)")
            }
        }
    }

    func selectWallpaperAsync(id: String) async throws {
        let bundle = try await bridge.selectWallpaper(id: id)
        apply(bundle)
    }

    /// The playable wallpaper after the one on `displayId`, in library order and
    /// wrapping around; the first one when that display shows none. Nil when there
    /// is nothing else to switch to.
    func nextWallpaperID(displayId: String) -> String? {
        let candidates = librarySnapshot.wallpapers.filter(\.supported).map(\.id)
        let current = monitorInformationSnapshot.rows.first { $0.displayId == displayId }?.wallpaperId
        guard let index = current.flatMap(candidates.firstIndex(of:)) else { return candidates.first }
        let next = candidates[(index + 1) % candidates.count]
        return next == current ? nil : next
    }

    func previousWallpaperID(displayId: String) -> String? {
        history.previous(on: displayId,
            current: monitorInformationSnapshot.rows.first { $0.displayId == displayId }?.wallpaperId,
            available: Set(librarySnapshot.wallpapers.filter(\.supported).map(\.id)))
    }

    func activatePreviousWallpaperAsync(displayId: String) async throws {
        try validateActivationTarget(displayId)
        guard let id = previousWallpaperID(displayId: displayId) else {
            throw WallpaperActionError(message: String(localized: "This display has no previous wallpaper still in your library."))
        }
        try await activateWallpaperAsync(id: id, displayId: displayId, origin: .user, returningToPrevious: true)
    }

    /// Makes `id` the wallpaper of `displayId`. Only the user's own `origin` reports a manual
    /// choice and counts toward the support prompt; the other origins are the app acting on
    /// its own, so a caller that does not say is treated as automatic. Every call leaves one
    /// log line saying who asked and how it ended ([ActivationLog]). `restarting` says the
    /// display showed this wallpaper until the caller took it off to load it afresh, so the
    /// display gains no wallpaper it did not have: that is not a first apply of it.
    /// `releasesHold` is for a command the user gave that carries out its activations under
    /// another origin (Apply to all displays): the wallpaper it names is the user's choice as far
    /// as a crash hold goes, so it opens a held wallpaper and lifts the hold, while the origin
    /// keeps deciding what is reported as a choice.
    func activateWallpaperAsync(id: String, displayId: String, origin: ActivationOrigin = .automation,
                                returningToPrevious: Bool = false, recordsHistory: Bool = true,
                                restarting: Bool = false, releasesHold: Bool = false) async throws {
        let started = ContinuousClock.now
        do {
            let result = try await performActivation(
                id: id, displayId: displayId, origin: origin,
                returningToPrevious: returningToPrevious, recordsHistory: recordsHistory,
                restarting: restarting, releasesHold: releasesHold)
            logActivation(.activation, wallpaper: id, display: displayId, origin: origin,
                          outcome: .init(result), since: started)
        } catch {
            logActivation(.activation, wallpaper: id, display: displayId, origin: origin,
                          outcome: .failed(ActivationLog.failure(of: error)), since: started)
            throw error
        }
    }

    /// The activation itself, without the log line: internal so a test can read its result.
    func performActivation(id: String, displayId: String, origin: ActivationOrigin,
                           returningToPrevious: Bool, recordsHistory: Bool,
                           restarting: Bool = false, releasesHold: Bool = false) async throws -> ActivationResult {
        await waitForIdleActivation()
        try requireIdleWallpaperEdits(id: id)
        guard librarySnapshot.wallpapers.contains(where: { $0.id == id }) else {
            throw WallpaperActionError(message: String(localized: "This wallpaper is no longer in your library. Refresh Library and choose another wallpaper."))
        }
        activatingWallpaperID = id
        defer { activatingWallpaperID = nil; resumeActivationWaiters() }
        try await selectWallpaperAsync(id: id)
        guard !activationNeedsRefresh else {
            throw WallpaperActionError(message: String(localized: "Refresh all wallpaper state before applying again."))
        }
        try validateActivationTarget(displayId)
        guard let options = wallpaperOptionsSnapshot, options.wallpaperId == id else {
            throw WallpaperActionError(message: String(localized: "Wallpaper settings are unavailable. Refresh Library and retry."))
        }
        // A wallpaper held back after a crash keeps its display assignment, so the display reads as
        // showing it while it has no scene. The user choosing it again is the way back from the
        // hold, so that choice must reach the bridge, which lifts the hold on a user-initiated
        // apply. An automatic origin still stops here, or a rotation would reopen the wallpaper
        // that crashed the app every time it came round to it.
        let userInitiated = origin.isUserChoice || releasesHold
        let reopensHeld = userInitiated && heldWallpaperIDs.contains(id)
        if !reopensHeld, isWallpaperActive(id: id, displayId: displayId), !options.dirty,
           !wallpaperAppliesNeedingSave.contains(id), !editorState.hasPendingEdits(wallpaperID: id) {
            if origin.isUserChoice { onUserWallpaperChoice?(id, displayId) }
            return .noOp
        }
        guard options.supported else {
            throw WallpaperActionError(message: String(localized: "This wallpaper type cannot be played on macOS. You can still inspect or remove it from your library."))
        }
        guard let row = options.displayConfigurations.first(where: { $0.displayId == displayId }) else {
            throw WallpaperActionError(message: String(localized: "No configuration is available for this display. Refresh Displays and retry."))
        }
        try validatePendingWallpaperEdits(id: id, options: options)
        try await validateWallpaperForPlayback(id: id)
        try await commitPendingWallpaperEditsAsync(id: id)
        // Validation and async draft commits may outlive a display topology change.
        try validateActivationTarget(displayId)
        let previouslyActive = isWallpaperActive(id: id, displayId: displayId)
        let previousAssignments = independentAssignments()
        let held = switchHoldDisplays(for: displayId)
        await willSwitchWallpaper?(held)
        var applyCompleted = false
        var settled = false
        do {
            try await setDisplayConfigEnabledAsync(wallpaperId: id, displayId: displayId, enabled: true)
            try await applyValidatedWallpaperOptionsAsync(wallpaperId: id, userInitiated: userInitiated)
            applyCompleted = true
            didSettleWallpaperSwitch?(held)
            settled = true
            try validateActivationTarget(displayId)
            guard isWallpaperActive(id: id, displayId: displayId) else {
                throw WallpaperActionError(message: String(localized: "The display did not report this wallpaper as active. Refresh Displays and retry."))
            }
        } catch {
            if !settled { didAbandonWallpaperSwitch?(held) }
            // A bridge error may happen after reconciliation. Never infer rollback from a stale bundle.
            try await resyncAfterFailedApplyAsync(cause: error)
            if isWallpaperActive(id: id, displayId: displayId), applyCompleted || !previouslyActive {
                throw WallpaperActionError(message: String(localized: "The display assignment changed, but the operation could not be fully saved: \(error.localizedDescription)"))
            }
            do {
                try await setDisplayConfigEnabledAsync(wallpaperId: id, displayId: displayId, enabled: row.enabled)
            } catch let restoreError {
                activationNeedsRefresh = true
                throw WallpaperActionError(message: String(localized: "Could not apply the wallpaper: \(error.localizedDescription). Could not restore the display draft: \(restoreError.localizedDescription). Refresh all wallpaper state before retrying."))
            }
            throw error
        }
        if recordsHistory { recordHistory(before: previousAssignments, returningDisplay: returningToPrevious ? displayId : nil) }
        reportSuccessfulApply(wallpaperID: id)
        if origin.isUserChoice { onUserWallpaperChoice?(id, displayId) }
        // Startup, playlist rotation and update reloads never solicit support. Wait until
        // saving and the final display check both succeed for an explicit activation.
        if origin.isUserChoice, !previouslyActive, !restarting {
            supportPrompt?.recordSuccessfulActivation(wallpaperID: id)
        }
        return .applied
    }

    private func logActivation(_ kind: ActivationLog.Kind, wallpaper: String, display: String,
                               origin: ActivationOrigin, outcome: ActivationLog.Outcome,
                               since started: ContinuousClock.Instant) {
        // A skipped reload did no work, so it has no duration to report.
        let milliseconds = outcome == .skipped ? nil : ActivationLog.milliseconds(started.duration(to: .now))
        activationLogWriter(
            ActivationLog.line(kind, wallpaper: wallpaper, display: display, origin: origin,
                               outcome: outcome, milliseconds: milliseconds),
            outcome.isFailure)
        telemetry?.recordActivation(kind, wallpaper: wallpaper, origin: origin,
                                    outcome: outcome, milliseconds: milliseconds)
    }

    /// Restarts `id` on `displayId`: the inspector's **Reapply wallpaper**, for a wallpaper that
    /// froze, went blank or shows stale content. Applying the wallpaper a display already shows
    /// does nothing, so this loads it afresh the way an update reload does. A wallpaper the display
    /// does not show yet is simply applied.
    ///
    /// Everything that can refuse is checked before the display lets go of the wallpaper, so a
    /// wallpaper that can no longer load never leaves the display empty. Call it inside the
    /// display's command slot, as the panel does, so no other change slips in between the two steps.
    func reapplyWallpaperAsync(id: String, displayId: String) async throws {
        guard isWallpaperActive(id: id, displayId: displayId) else {
            try await activateWallpaperAsync(id: id, displayId: displayId, origin: .user)
            return
        }
        let started = ContinuousClock.now
        do {
            try validateActivationTarget(displayId)
            try requireIdleWallpaperEdits(id: id)
            if let options = wallpaperOptionsSnapshot, options.wallpaperId == id {
                try validatePendingWallpaperEdits(id: id, options: options)
            }
            try await validateWallpaperForPlayback(id: id)
            try await ejectWallpaperFromDisplayAsync(displayId: displayId, wallpaperId: id)
            try await activateWallpaperAsync(id: id, displayId: displayId, origin: .user,
                                             recordsHistory: false, restarting: true)
            logActivation(.reapply, wallpaper: id, display: displayId, origin: .user,
                          outcome: .applied, since: started)
        } catch {
            logActivation(.reapply, wallpaper: id, display: displayId, origin: .user,
                          outcome: .failed(ActivationLog.failure(of: error)), since: started)
            throw error
        }
    }

    /// Loads a wallpaper's files afresh on every display showing it, after an update replaced
    /// them: applying it again alone would find nothing changed and keep what is loaded. Each
    /// display goes through its own command slot, so a switch the user asks for meanwhile wins:
    /// a reload still waiting is replaced by it, and one that waited behind it finds the display
    /// showing something else and leaves it alone. A reload that finds the user's choice waiting
    /// is dropped, and the files load on the next update or launch. Each display logs one
    /// `reload` line, whether it reloaded, gave way or failed.
    ///
    /// `displayId` limits the reload to one display. That is the Retry for a scene that stopped
    /// drawing, which loads the same files again, so the posters made from them stay valid.
    func reloadWallpaperAsync(id: String, displayId: String? = nil) async throws {
        if displayId == nil { wallpaperContentRevision &+= 1 }
        let displays = monitorInformationSnapshot.rows.filter {
            $0.wallpaperId == id && $0.mirrorTargetDisplayId == nil
                && (displayId == nil || $0.displayId == displayId)
        }.map(\.displayId)
        for display in displays {
            let started = ContinuousClock.now
            do {
                var reloaded = false
                let ran = try await commands.run(slot: Self.activationSlot(displayId: display), subject: id, origin: .updateReload) {
                    guard self.isWallpaperActive(id: id, displayId: display) else { return }
                    try await self.ejectWallpaperFromDisplayAsync(displayId: display, wallpaperId: id)
                    try await self.activateWallpaperAsync(id: id, displayId: display, origin: .updateReload)
                    reloaded = true
                }
                logActivation(.reload, wallpaper: id, display: display, origin: .updateReload,
                              outcome: ran && reloaded ? .applied : .skipped, since: started)
            } catch {
                logActivation(.reload, wallpaper: id, display: display, origin: .updateReload,
                              outcome: .failed(ActivationLog.failure(of: error)), since: started)
                throw error
            }
        }
    }

    /// The user's Retry for a scene that stopped drawing after a rendering failure: loads the
    /// wallpaper on `displayId` afresh. Applying it again would find it already active and
    /// change nothing, so the stopped scene would stay as it is. The reload is queued in the
    /// display's slot, so a newer choice for that display replaces it, and nothing retries
    /// by itself: a scene that stops again stays stopped until the user asks once more.
    ///
    /// A display that mirrors another presents its own scene of the wallpaper it mirrors, but
    /// holds no assignment of its own: the wallpaper is applied to and taken off the display it
    /// mirrors, never the mirror. A mirror's Retry therefore reloads that source display, which
    /// opens a new scene on both.
    func retryStoppedSceneAsync(displayId: String) async throws {
        let rows = monitorInformationSnapshot.rows
        guard let shown = rows.first(where: { $0.displayId == displayId && !$0.wallpaperId.isEmpty }),
              let owner = rows.first(where: {
                  $0.displayId == (shown.mirrorTargetDisplayId ?? displayId)
                      && $0.mirrorTargetDisplayId == nil && $0.wallpaperId == shown.wallpaperId
              })
        else {
            throw WallpaperActionError(message: String(localized: "No wallpaper is running on this display."))
        }
        try await reloadWallpaperAsync(id: owner.wallpaperId, displayId: owner.displayId)
    }

    /// The live CoreGraphics ids of the displays that change when `displayId` gets another
    /// wallpaper: the display itself and every display mirroring it, which presents its own
    /// scene of the same wallpaper.
    func switchHoldDisplays(for displayId: String) -> [UInt32] {
        var seen = Set<UInt32>()
        return monitorInformationSnapshot.rows
            .filter { $0.displayId == displayId || $0.mirrorTargetDisplayId == displayId }
            .compactMap { ResolvedDisplayTitles.liveDisplayID($0.displayId, title: $0.title) }
            .filter { seen.insert($0).inserted }
    }

    func isWallpaperActive(id: String, displayId: String) -> Bool {
        monitorInformationSnapshot.rows.contains {
            $0.displayId == displayId && $0.wallpaperId == id && $0.mirrorTargetDisplayId == nil
        }
    }

    /// Refuses a display that cannot show its own wallpaper: gone, disabled or mirroring another.
    func validateActivationTarget(_ displayId: String) throws {
        guard let target = settingsSnapshot.displays.first(where: { $0.displayId == displayId }),
              target.enabled, target.mode == .standalone else {
            throw WallpaperActionError(message: String(localized: "The selected display is unavailable, disabled, or mirroring another display. Choose an enabled independent display in Settings."))
        }
    }

    /// Callers outside the command queue (downloads, imports, the menu bar's refresh) can
    /// reach the store while a wallpaper is being applied; they wait for it, not fail.
    /// Each caller claims its own flag before its next suspension, so the loop re-checks.
    private func waitForIdleActivation() async {
        while activatingWallpaperID != nil || applyingWallpaperID != nil || updatingPlaybackEnvironment {
            await withCheckedContinuation { activationWaiters.append($0) }
        }
    }

    /// Automatic presentation changes and display refreshes invalidate an in-flight
    /// engine apply, even when triggered by that apply's own window changes. Reserve
    /// the same lane in both directions, including the returned snapshot publication.
    /// Explicit Play/Pause stays outside this lane so the user can still interrupt.
    /// This lane is non-reentrant: an apply/activation or operation holding it must
    /// never await another lane-taking method (including through a callback).
    /// Suspend/unload deliberately wait too: they can invalidate engine apply even
    /// without returning a snapshot. Cancelled waiters stay parked until release,
    /// then fail the cancellation check without invoking their bridge operation.
    private func updatePlaybackEnvironment(_ operation: () async throws -> Void) async throws {
        await waitForIdleActivation()
        try Task.checkCancellation()
        updatingPlaybackEnvironment = true
        defer { updatingPlaybackEnvironment = false; resumeActivationWaiters() }
        try await operation()
    }

    private func resumeActivationWaiters() {
        let waiters = activationWaiters
        activationWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    private static let activationSlotPrefix = "activate:"
    static func activationSlot(displayId: String) -> String { activationSlotPrefix + displayId }
    static let selectionSlot = "select"

    /// Wallpapers whose switch is queued behind the running command, oldest first.
    var waitingActivationIDs: [String] {
        commands.waiting.compactMap {
            $0.slot?.hasPrefix(Self.activationSlotPrefix) == true ? $0.subject : nil
        }
    }

    func isWallpaperEditInProgress(id: String) -> Bool { activeWallpaperEdits[id, default: 0] > 0 }

    private func requireIdleWallpaperEdits(id: String) throws {
        guard !isWallpaperEditInProgress(id: id) else {
            throw WallpaperActionError(message: String(localized: "Wait for the pending setting to finish before applying."))
        }
    }

    private func beginWallpaperEdit(_ id: String) { activeWallpaperEdits[id, default: 0] += 1 }
    private func endWallpaperEdit(_ id: String) {
        if activeWallpaperEdits[id, default: 0] <= 1 { activeWallpaperEdits.removeValue(forKey: id) }
        else { activeWallpaperEdits[id, default: 0] -= 1 }
    }

    private func validatePendingWallpaperEdits(id: String, options: BridgeWallpaperOptionsSnapshot) throws {
        for (key, draft) in editorState.scalingDrafts where key.wallpaperID == id {
            guard draft.value != nil,
                  options.displayConfigurations.contains(where: { $0.displayId == key.fieldID }) else {
                throw WallpaperActionError(message: draft.errorMessage ?? String(localized: "A pending display setting is no longer available. Revert it before applying."))
            }
        }
        for key in editorState.propertyTextDrafts.keys where key.wallpaperID == id {
            guard options.properties.contains(where: { $0.id == key.fieldID && $0.kind == .textInput && $0.enabled }) else {
                throw WallpaperActionError(message: String(localized: "A pending property is no longer editable. Revert it before applying."))
            }
        }
    }

    func commitPendingWallpaperEditsAsync(id: String) async throws {
        let options = try await wallpaperOptionsSnapshotAsync(wallpaperId: id)
        try validatePendingWallpaperEdits(id: id, options: options)
        let scaling = editorState.scalingDrafts.filter { $0.key.wallpaperID == id }.sorted { $0.key.fieldID < $1.key.fieldID }
        let text = editorState.propertyTextDrafts.filter { $0.key.wallpaperID == id }.sorted { $0.key.fieldID < $1.key.fieldID }
        for (key, draft) in scaling {
            if let value = draft.value {
                try await editScalingFactorAsync(wallpaperId: id, displayId: key.fieldID, factor: value)
            }
        }
        for (key, value) in text {
            try await editPropertyAsync(wallpaperId: id, propertyId: key.fieldID, value: .string(value: value))
        }
    }

    func wallpaperOptionsSnapshotAsync(
        wallpaperId: String
    ) async throws -> BridgeWallpaperOptionsSnapshot {
        try await bridge.wallpaperOptionsSnapshot(wallpaperId: wallpaperId)
    }

    /// Uncommitted text/scale fields stay local too: preview copies them without invoking
    /// any setter, saving a draft, changing selection or applying to a display.
    func wallpaperPreviewRequestAsync(id: String, displayID: String,
                                     textOverrides: [String: String] = [:]) async throws -> WallpaperPreviewRequest {
        let options = try await wallpaperOptionsSnapshotAsync(wallpaperId: id)
        if !textOverrides.isEmpty {
            let allowed = Set(options.properties.filter { $0.kind == .textInput && $0.enabled }.map(\.id))
            guard textOverrides.count <= 1_000, textOverrides.keys.allSatisfy(allowed.contains),
                  textOverrides.values.reduce(0, { $0 + $1.utf8.count }) <= 1024 * 1024 else {
                throw WallpaperActionError(message: String(localized: "Some preview options are no longer available. Refresh the library and try again."))
            }
        }
        // A slider or colour still being dragged shows in the preview as it does on the displays.
        let descriptor = try await bridge.wallpaperPreview(
            wallpaperId: id, displayId: displayID, pending: editorState.propertyPreviews(wallpaperID: id))
        try Task.checkCancellation()
        var request = try WallpaperPreviewRequest(descriptor)
        request.frozenPropertyIDs = Set(options.properties.filter { Self.previewHoldsAtLoadedValue($0.kind) }.map(\.id))
        if let draft = editorState.scalingDrafts[.init(wallpaperID: id, fieldID: displayID)] {
            guard let value = draft.value else {
                throw WallpaperActionError(message: draft.errorMessage ?? String(localized: "Enter a valid scale before previewing."))
            }
            request.scalingFactor = value
        }
        if let data = request.propertiesJSON.data(using: .utf8),
           var properties = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var texts = Dictionary(uniqueKeysWithValues: editorState.propertyTextDrafts.filter { $0.key.wallpaperID == id }
                .map { ($0.key.fieldID, $0.value) })
            texts.merge(textOverrides, uniquingKeysWith: { _, latest in latest })
            for (key, value) in texts where properties[key] != nil {
                if request.kind == .web, var property = properties[key] as? [String: Any] {
                    property["value"] = value
                    properties[key] = property
                } else { properties[key] = value }
            }
            request.propertiesJSON = String(decoding: try JSONSerialization.data(withJSONObject: properties, options: [.sortedKeys]), as: UTF8.self)
        }
        return request
    }

    /// A picture or file is read when a wallpaper loads, so a running preview keeps the one it
    /// started with and offers a reload when the draft picks another.
    nonisolated static func previewHoldsAtLoadedValue(_ kind: BridgePropertyKind) -> Bool {
        switch kind {
        case .texture, .file, .directory: true
        default: false
        }
    }

    func setFilterAsync(kind: BridgeWallpaperKind, enabled: Bool) async throws {
        let bundle = try await bridge.setFilter(kind: kind, enabled: enabled)
        apply(bundle)
    }

    func setVolumeAsync(wallpaperId: String, volume: Float) async throws {
        beginWallpaperEdit(wallpaperId)
        defer { endWallpaperEdit(wallpaperId) }
        let bundle = try await bridge.setVolume(wallpaperId: wallpaperId, volume: volume)
        apply(bundle)
    }

    func setMutedAsync(wallpaperId: String, muted: Bool) async throws {
        beginWallpaperEdit(wallpaperId)
        defer { endWallpaperEdit(wallpaperId) }
        let bundle = try await bridge.setMuted(wallpaperId: wallpaperId, muted: muted)
        apply(bundle)
    }

    func setAudioResponseEnabledAsync(wallpaperId: String, enabled: Bool) async throws {
        beginWallpaperEdit(wallpaperId)
        defer { endWallpaperEdit(wallpaperId) }
        do {
            let bundle = try await bridge.setAudioResponseEnabled(wallpaperId: wallpaperId, enabled: enabled)
            apply(bundle)
        } catch {
            // Capture failures roll the saved option back; discard any in-flight snapshot.
            try? await refreshAllAsync()
            throw error
        }
    }

    func setMediaIntegrationEnabledAsync(wallpaperId: String, enabled: Bool) async throws {
        beginWallpaperEdit(wallpaperId)
        defer { endWallpaperEdit(wallpaperId) }
        let bundle = try await bridge.setMediaIntegrationEnabled(wallpaperId: wallpaperId, enabled: enabled)
        apply(bundle)
    }

    func setDisplayConfigEnabledAsync(
        wallpaperId: String,
        displayId: String,
        enabled: Bool
    ) async throws {
        beginWallpaperEdit(wallpaperId)
        defer { endWallpaperEdit(wallpaperId) }
        let bundle = try await bridge.setDisplayConfigEnabled(
            wallpaperId: wallpaperId,
            displayId: displayId,
            enabled: enabled
        )
        apply(bundle)
    }

    func setScalingModeAsync(
        wallpaperId: String,
        displayId: String,
        mode: BridgeScalingMode
    ) async throws {
        beginWallpaperEdit(wallpaperId)
        defer { endWallpaperEdit(wallpaperId) }
        let bundle = try await bridge.setScalingMode(
            wallpaperId: wallpaperId,
            displayId: displayId,
            mode: mode
        )
        apply(bundle)
    }

    /// Moves a wallpaper on one display: each axis is a fraction from 0 (left, top) to 1
    /// (right, bottom) of the room the display leaves around it, and an axis passed as `nil`
    /// keeps its saved value. Like the scaling mode and unlike the scale factor, the running
    /// scene follows and the position is saved at once, so Apply and Revert neither wait
    /// for it nor undo it.
    func setDisplayPositionAsync(
        wallpaperId: String,
        displayId: String,
        panX: Double?,
        panY: Double?
    ) async throws {
        beginWallpaperEdit(wallpaperId)
        defer { endWallpaperEdit(wallpaperId) }
        let bundle = try await bridge.setDisplayPosition(
            wallpaperId: wallpaperId,
            displayId: displayId,
            panX: panX,
            panY: panY
        )
        apply(bundle)
        AppLog.debug("display position: \(wallpaperId) on \(displayId), x \(panX.map { String($0) } ?? "kept"), y \(panY.map { String($0) } ?? "kept")")
        onDisplayFramingChanged?(wallpaperId, displayId)
    }

    /// Shows a wallpaper at a position on one display while a slider is still being dragged:
    /// the running scene follows, but nothing is saved, no snapshot changes and nothing that
    /// reacts to a move (the Mission Control picture, the lock screen) is told. The drag ends
    /// with ``setDisplayPositionAsync(wallpaperId:displayId:panX:panY:)``, which is what keeps
    /// the position. Axes are read as there; a display no scene draws is not an error.
    func previewDisplayPositionAsync(
        wallpaperId: String,
        displayId: String,
        panX: Double?,
        panY: Double?
    ) async throws {
        try await bridge.previewDisplayPosition(
            wallpaperId: wallpaperId,
            displayId: displayId,
            panX: panX,
            panY: panY
        )
    }

    func editScalingFactorAsync(wallpaperId: String, displayId: String, factor: Double) async throws {
        beginWallpaperEdit(wallpaperId)
        defer { endWallpaperEdit(wallpaperId) }
        let bundle = try await bridge.editScalingFactor(wallpaperId: wallpaperId, displayId: displayId, factor: factor)
        apply(bundle)
    }

    func setTargetFpsAsync(wallpaperId: String, displayId: String, fps: UInt32) async throws {
        beginWallpaperEdit(wallpaperId)
        defer { endWallpaperEdit(wallpaperId) }
        let bundle = try await bridge.setTargetFps(wallpaperId: wallpaperId, displayId: displayId, fps: fps)
        apply(bundle)
    }

    func editPropertyAsync(
        wallpaperId: String,
        propertyId: String,
        value: BridgePropertyValue
    ) async throws {
        try await changeDraftProperties(wallpaperId, replacing: propertyId) {
            try await self.bridge.editProperty(wallpaperId: wallpaperId, propertyId: propertyId, value: value)
        }
    }

    /// Shows the value a slider or colour is being dragged to on whatever follows the wallpaper's
    /// pending properties, the preview window and, with the choice on, the displays, without
    /// making it an edit: nothing is dirty, saved or announced, and the edit that ends the drag
    /// (`editPropertyAsync`) is what keeps the value. The value is held until that edit, a restore
    /// of the property, a revert, an apply or another wallpaper's inspector replaces it, and
    /// every update of the previews in the meantime includes it.
    ///
    /// The panel sends one step at a time and waits for this to return, so the displays are
    /// updated here instead of after the quiet period an edit waits out: a drag has no quiet.
    /// A step that comes while the wallpaper is being applied or reverted is dropped.
    func previewPropertyAsync(wallpaperId: String, propertyId: String, value: BridgePropertyValue) async {
        guard applyingWallpaperID != wallpaperId else { return }
        editorState.setPropertyPreview(value, key: .init(wallpaperID: wallpaperId, fieldID: propertyId))
        onPropertyDragged?(wallpaperId)
        guard canShowEditsOnDesktop(wallpaperId) else { return }
        await showPropertyEditsOnDesktop(wallpaperId)
    }

    /// The path a `file` or `directory` property points at. `nil` clears it; the engine
    /// stores the string verbatim, so what is passed here is what the panel reads back.
    func setPropertyPathAsync(wallpaperId: String, propertyId: String, path: String?) async throws {
        beginWallpaperEdit(wallpaperId)
        defer { endWallpaperEdit(wallpaperId) }
        let bundle = try await bridge.setPropertyPath(wallpaperId: wallpaperId, propertyId: propertyId, path: path)
        invalidateHostAsset?(wallpaperId, propertyId)
        apply(bundle)
        propertyDraftEdited(wallpaperId)
    }

    func restorePropertyDefaultAsync(wallpaperId: String, propertyId: String) async throws {
        try await changeDraftProperties(wallpaperId, replacing: propertyId) {
            try await self.bridge.restorePropertyDefault(wallpaperId: wallpaperId, propertyId: propertyId)
        }
    }

    /// Stages the authored default for every property except the files and folders the user chose,
    /// which are saved as they are picked and keep their own Clear. Revert undoes it.
    func restoreAllPropertyDefaultsAsync(wallpaperId: String) async throws {
        try await changeDraftProperties(wallpaperId, replacing: nil) {
            try await self.bridge.restoreAllPropertyDefaults(wallpaperId: wallpaperId)
        }
    }

    /// Runs a call that changes the wallpaper's pending properties. What the call replaces, the
    /// value of one property or of all of them, is no longer something a drag is showing, whether
    /// the call took or was refused: the draft is what the previews follow from then on.
    private func changeDraftProperties(
        _ wallpaperId: String,
        replacing propertyId: String?,
        _ call: () async throws -> BridgeWallpaperMutationBundle
    ) async throws {
        beginWallpaperEdit(wallpaperId)
        defer { endWallpaperEdit(wallpaperId) }
        let bundle: BridgeWallpaperMutationBundle
        do {
            bundle = try await call()
        } catch {
            if dropPropertyPreviews(wallpaperId, propertyId: propertyId) { propertyDraftEdited(wallpaperId) }
            throw error
        }
        dropPropertyPreviews(wallpaperId, propertyId: propertyId)
        apply(bundle)
        propertyDraftEdited(wallpaperId)
    }

    @discardableResult
    private func dropPropertyPreviews(_ wallpaperId: String, propertyId: String?) -> Bool {
        guard let propertyId else { return editorState.clearPropertyPreviews(wallpaperID: wallpaperId) }
        return editorState.clearPropertyPreview(.init(wallpaperID: wallpaperId, fieldID: propertyId))
    }

    /// An edit changed the wallpaper's pending properties: tells whatever follows the draft, and
    /// with the choice on shows the draft on the displays once the edits pause. Revert and Apply
    /// end the draft instead and tell only the first, because the bridge puts the saved look back
    /// or loads it itself.
    private func propertyDraftEdited(_ wallpaperId: String) {
        onPropertyDraftChanged?(wallpaperId)
        showPendingPropertyEditsOnDesktop(wallpaperId)
    }

    private func showPendingPropertyEditsOnDesktop(_ wallpaperId: String) {
        guard canShowEditsOnDesktop(wallpaperId) else { return }
        desktopPropertyPreviews.schedule(key: wallpaperId) { [weak self] in
            await self?.showPropertyEditsOnDesktop(wallpaperId)
        }
    }

    private func canShowEditsOnDesktop(_ wallpaperId: String) -> Bool {
        guard showsPropertyEditsOnDesktop(), applyingWallpaperID != wallpaperId else { return false }
        // A video has no properties to show and a web page gets its own delivery.
        if let options = wallpaperOptionsSnapshot, options.wallpaperId == wallpaperId, options.kind != .projectScene {
            return false
        }
        return true
    }

    private func forgetPropertyEditsOnDesktop(_ wallpaperId: String) {
        propertyEditsOnDesktop.remove(wallpaperId)
        desktopPreviewProblems.removeValue(forKey: wallpaperId)
    }

    /// The bridge builds what it shows from the draft as it is when the call arrives, so a call
    /// that lands after a Revert or an Apply shows the saved look again, which is a no-op. The
    /// values being dragged ride along, so an update of the edits never takes a drag back a step.
    private func showPropertyEditsOnDesktop(_ wallpaperId: String) async {
        // The wait can outlive the choice. A Revert or an Apply drops the update that is waiting.
        guard showsPropertyEditsOnDesktop() else { return }
        propertyEditsOnDesktop.insert(wallpaperId)
        do {
            try await bridge.previewWallpaperProperties(
                wallpaperId: wallpaperId, show: true, pending: editorState.propertyPreviews(wallpaperID: wallpaperId))
            desktopPreviewProblems.removeValue(forKey: wallpaperId)
        } catch {
            let problem = "properties: \(wallpaperId) could not show its pending edits on the desktop: \(error.localizedDescription)"
            if desktopPreviewProblems.updateValue(problem, forKey: wallpaperId) != problem { desktopPropertyPreviewLog(problem) }
        }
    }

    /// Puts the saved look back on every wallpaper whose displays were shown pending edits and
    /// drops the updates still waiting. The edits stay pending in the inspector. A wallpaper the
    /// bridge refuses keeps its mark, so asking again retries it.
    func stopShowingPropertyEditsOnDesktopAsync() async {
        desktopPropertyPreviews.cancelAll()
        for wallpaperId in propertyEditsOnDesktop.sorted() {
            do {
                try await bridge.previewWallpaperProperties(wallpaperId: wallpaperId, show: false, pending: [])
                forgetPropertyEditsOnDesktop(wallpaperId)
            } catch {
                desktopPropertyPreviewLog("properties: \(wallpaperId) could not put its saved look back on the desktop: \(error.localizedDescription)")
            }
        }
    }

    /// Whether the display with this live CoreGraphics id may be drawing pending property edits:
    /// it shows a wallpaper that was shown some, a mirror of that display's included. The
    /// Mission Control picture is not taken from such a display, because it is read back from what
    /// the scene draws and would keep an edit nobody saved. A scene that loaded again meanwhile
    /// draws the saved look but stays held until the edit ends, so its picture is older, not unsaved.
    func isShowingPropertyEdits(onDisplay liveDisplayID: String) -> Bool {
        guard !propertyEditsOnDesktop.isEmpty else { return false }
        return monitorInformationSnapshot.rows.contains { row in
            propertyEditsOnDesktop.contains(row.wallpaperId)
                && ResolvedDisplayTitles.liveDisplayID(row.displayId, title: row.title).map(String.init) == liveDisplayID
        }
    }

    func setDisplayEnabledAsync(displayId: String, enabled: Bool) async throws {
        let bundle = try await bridge.setDisplayEnabled(displayId: displayId, enabled: enabled)
        apply(bundle)
    }

    func setDisplayModeAsync(displayId: String, mode: BridgeDisplayMode) async throws {
        let bundle = try await bridge.setDisplayMode(displayId: displayId, mode: mode)
        apply(bundle)
    }

    func setMirrorTargetAsync(displayId: String, targetDisplayId: String) async throws {
        let bundle = try await bridge.setMirrorTarget(displayId: displayId, targetDisplayId: targetDisplayId)
        apply(bundle)
    }

    func setMirrorScalingModeAsync(displayId: String, mode: BridgeScalingMode) async throws {
        let bundle = try await bridge.setMirrorScalingMode(displayId: displayId, mode: mode)
        apply(bundle)
    }

    func setMirrorScalingFactorAsync(displayId: String, factor: Double) async throws {
        let bundle = try await bridge.setMirrorScalingFactor(displayId: displayId, factor: factor)
        apply(bundle)
    }

    func setMirrorTargetFpsAsync(displayId: String, fps: UInt32) async throws {
        let bundle = try await bridge.setMirrorTargetFps(displayId: displayId, fps: fps)
        apply(bundle)
    }

    func setMirrorVolumeAsync(displayId: String, volume: Float) async throws {
        let bundle = try await bridge.setMirrorVolume(displayId: displayId, volume: volume)
        apply(bundle)
    }

    func setMirrorMutedAsync(displayId: String, muted: Bool) async throws {
        let bundle = try await bridge.setMirrorMuted(displayId: displayId, muted: muted)
        apply(bundle)
    }

    func setLaunchAtLoginAsync(enabled: Bool) async throws {
        let bundle = try await bridge.setLaunchAtLogin(enabled: enabled)
        apply(bundle)
    }

    func setBatteryModeAsync(_ mode: BridgeBatteryMode) async throws {
        let bundle = try await bridge.setBatteryMode(mode: mode)
        apply(bundle)
    }

    func setVerboseLoggingAsync(enabled: Bool) async throws {
        let bundle = try await bridge.setVerboseLogging(enabled: enabled)
        apply(bundle)
    }

    func setRenderScaleAsync(_ scale: Float) async throws {
        let bundle = try await bridge.setRenderScale(scale: scale)
        apply(bundle)
    }

    func setBatteryQualityProfileAsync(renderScale: Float, targetFps: UInt32) async throws {
        let bundle = try await bridge.setBatteryQualityProfile(
            renderScale: renderScale, targetFps: targetFps)
        apply(bundle)
    }

    func setFrameRateCapAsync(_ cap: UInt32?) async throws {
        let bundle = try await bridge.setFrameRateCap(cap: cap)
        apply(bundle)
    }

    func setPresentationUnloadedAsync(_ unloaded: Bool) async throws {
        try await updatePlaybackEnvironment {
            let bundle = try await bridge.setPresentationUnloaded(unloaded: unloaded)
            apply(bundle)
        }
    }

    func setAudioSuppressedAsync(_ suppressed: Bool) async throws {
        try await updatePlaybackEnvironment {
            let bundle = try await bridge.setAudioSuppressed(suppressed: suppressed)
            apply(bundle)
        }
    }

    /// Asks the bridge to run every wallpaper at the reduced-quality profile for as long as
    /// `reductions` is not empty, on top of the battery mode the user saved. The bridge keeps
    /// it for this run only and lowers frame rate and render scale live, without pausing or
    /// rebuilding anything. Like the audio flag it is an automatic change of the environment,
    /// so it waits for an in-flight Apply instead of invalidating it.
    func setQualityThrottleAsync(_ reductions: Set<QualityReduction>) async throws {
        try await updatePlaybackEnvironment {
            let bundle = try await bridge.setQualityThrottle(
                causes: reductions.sorted().map(\.bridgeCause))
            apply(bundle)
        }
    }

    /// Names the language a wallpaper's own label tables are read in. The bridge keeps it only
    /// for this run, so the app sends it at launch and again whenever the language changes.
    /// An inspector that is already open is read again, so its labels change with the language
    /// instead of waiting for the next edit.
    func setLabelLanguageAsync(_ language: AppLanguage) async throws {
        try await bridge.setLabelLanguages(locales: language.labelLocales)
        guard let id = wallpaperOptionsSnapshot?.wallpaperId else { return }
        let options = try await bridge.wallpaperOptionsSnapshot(wallpaperId: id)
        // Another wallpaper may have been opened while the read was in flight.
        guard wallpaperOptionsSnapshot?.wallpaperId == id else { return }
        wallpaperOptionsSnapshot = options
        finishSnapshotApply()
    }

    /// Scene subgraph reuse and redundant-pass removal. The engine publishes the saved
    /// preference rather than a reading taken from a running scene, so the snapshot this
    /// returns is what the page reports back.
    func setSceneOptimizationEnabledAsync(_ enabled: Bool) async throws {
        let bundle = try await bridge.setSceneOptimizationEnabled(enabled: enabled)
        apply(bundle)
    }

    /// Whole-scene on-demand updating. Off by default. The bundle carries back the saved
    /// preference plus `sceneUpdateModes`, which is the live per-scene read-back: the
    /// preference being on does not mean any scene actually stopped ticking.
    func setSceneOnDemandEnabledAsync(_ enabled: Bool) async throws {
        let bundle = try await bridge.setSceneOnDemandEnabled(enabled: enabled)
        apply(bundle)
    }

    /// Direct NV12 plane sampling inside native Metal scenes. Off by default and
    /// experimental. A preference: the `videoPath` of each `sceneRenderers` row is
    /// what each running scene's video textures actually did.
    func setSceneVideoPlaneSamplingEnabledAsync(_ enabled: Bool) async throws {
        let bundle = try await bridge.setSceneVideoPlaneSamplingEnabled(enabled: enabled)
        apply(bundle)
    }

    /// How many pixels a 2D scene is rasterized with, `"display"` or `"canvas"`. A preference every
    /// running 2D scene follows live, by resizing its render targets in place: nothing is reparsed (on
    /// Native Metal the scene's own video layers are reopened, as for any render-scale change).
    func setSceneResolutionAsync(_ mode: String) async throws {
        let bundle = try await bridge.setSceneResolution(mode: mode)
        apply(bundle)
    }

    func applyWallpaperOptionsAsync(wallpaperId: String, userInitiated: Bool = false) async throws {
        await waitForIdleActivation()
        try requireIdleWallpaperEdits(id: wallpaperId)
        guard !activationNeedsRefresh else {
            throw WallpaperActionError(message: String(localized: "Refresh all wallpaper state before applying again."))
        }
        applyingWallpaperID = wallpaperId
        defer { applyingWallpaperID = nil; resumeActivationWaiters() }
        // The scenes are loaded from what is saved, so an update still waiting would only show an
        // edit that is about to be part of it.
        desktopPropertyPreviews.cancel(wallpaperId)
        let previousDisplays = Set(monitorInformationSnapshot.rows.filter {
            $0.wallpaperId == wallpaperId && $0.mirrorTargetDisplayId == nil
        }.map(\.displayId))
        let previousAssignments = independentAssignments()
        try await validateWallpaperForPlayback(id: wallpaperId)
        try await commitPendingWallpaperEditsAsync(id: wallpaperId)
        do {
            try await applyValidatedWallpaperOptionsAsync(wallpaperId: wallpaperId, userInitiated: userInitiated)
        } catch {
            // The engine restores its previous configuration when an apply fails,
            // so re-read it instead of leaving the UI stuck behind a manual refresh.
            try await resyncAfterFailedApplyAsync(cause: error)
            throw error
        }
        onPropertyDraftChanged?(wallpaperId)
        recordHistory(before: previousAssignments)
        reportSuccessfulApply(wallpaperID: wallpaperId)
        if userInitiated {
            for (display, wallpaper) in independentAssignments() where previousAssignments[display] != wallpaper {
                onUserWallpaperChoice?(wallpaper, display)
            }
        }
        if userInitiated, monitorInformationSnapshot.rows.contains(where: {
            $0.wallpaperId == wallpaperId && $0.mirrorTargetDisplayId == nil
                && !previousDisplays.contains($0.displayId)
        }) {
            supportPrompt?.recordSuccessfulActivation(wallpaperID: wallpaperId)
        }
    }

    private func independentAssignments() -> [String: String] {
        Dictionary(monitorInformationSnapshot.rows.compactMap { row in
            row.mirrorTargetDisplayId == nil && !row.wallpaperId.isEmpty ? (row.displayId, row.wallpaperId) : nil
        }, uniquingKeysWith: { _, latest in latest })
    }

    private func recordHistory(before: [String: String], returningDisplay: String? = nil) {
        for (display, wallpaper) in independentAssignments() where before[display] != wallpaper {
            history.recordSwitch(from: before[display], to: wallpaper, on: display,
                                 returningToPrevious: display == returningDisplay)
        }
    }

    private func reportSuccessfulApply(wallpaperID: String) {
        for (display, wallpaper) in independentAssignments() where wallpaper == wallpaperID {
            onWallpaperApplied?(wallpaper, display)
        }
    }

    private func validateWallpaperForPlayback(id wallpaperId: String) async throws {
        let folder = ClientPaths.libraryURL.appendingPathComponent(wallpaperId, isDirectory: true)
        let manifestData = try Data(contentsOf: folder.appendingPathComponent("project.json"))
        let manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any] ?? [:]
        let entry = manifest["file"] as? String ?? ""
        func failure(_ code: Int, _ message: String) -> NSError {
            NSError(domain: "WallpaperMachine", code: code, userInfo: [NSLocalizedDescriptionKey: message])
        }
        switch (manifest["type"] as? String ?? "").lowercased() {
        case "video":
            let file = folder.appendingPathComponent(entry)
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard !entry.isEmpty, FileManager.default.isReadableFile(atPath: file.path),
                  values?.isRegularFile == true, (values?.fileSize ?? 0) > 0 else {
                throw failure(1, String(localized: "This video cannot be decoded. Import a complete, playable video file before applying it."))
            }
            // A format nothing can play is refused here, before any display changes.
            if let message = VideoFormatSupport.message(for: await videoFormatCheck(file)) {
                throw WallpaperActionError(message: message)
            }
        case "scene":
            let assets = ClientPaths.assetsURL
            guard ClientPaths.hasSceneAssets(at: assets) else {
                throw failure(2, String(localized: "This wallpaper is downloaded, but Wallpaper Engine’s shared scene resources are not installed. Choose Get shared resources in the wallpaper’s details, or go to Settings → Library & Steam."))
            }
            setenv("WALLPAPER_MACHINE_ASSETS_ROOT", assets.path, 1)
        case "web":
            guard !entry.isEmpty, FileManager.default.fileExists(atPath: folder.appendingPathComponent(entry).path) else {
                throw failure(3, String(localized: "This web wallpaper’s entry page is missing. Import the complete project folder, including its HTML file, before applying it."))
            }
        default:
            break
        }
    }

    /// `userInitiated` is what lets the apply open a wallpaper the load journal holds back after
    /// repeated crashes. A playlist, a rule or a schedule coming round to it must not: it would
    /// reopen the wallpaper that crashed the app, every time the rotation reaches it.
    private func applyValidatedWallpaperOptionsAsync(wallpaperId: String, userInitiated: Bool) async throws {
        do {
            let bundle = try await bridge.applyWallpaperOptions(wallpaperId: wallpaperId, userInitiated: userInitiated)
            apply(bundle)
            guard bundle.wallpaperOptions.wallpaperId == wallpaperId, !bundle.wallpaperOptions.dirty else {
                throw WallpaperActionError(message: String(localized: "Applying was interrupted by another playback or display change. Your pending edits have been kept. Refresh and retry."))
            }
            editorState.discard(wallpaperID: wallpaperId)
            wallpaperAppliesNeedingSave.remove(wallpaperId)
            // The scenes were loaded from what is saved, and activating a wallpaper commits its
            // pending edits through here too, so an update scheduled by them has nothing left to show.
            desktopPropertyPreviews.cancel(wallpaperId)
            forgetPropertyEditsOnDesktop(wallpaperId)
        } catch {
            wallpaperAppliesNeedingSave.insert(wallpaperId)
            // `activationNeedsRefresh` disables every Library action, so only the
            // callers may latch it, and only when they cannot re-read the engine.
            throw error
        }
    }

    /// Re-reads authoritative engine state after a failed apply. A successful
    /// re-read means the app and engine agree again, so the Library stays usable.
    /// Only a failed re-read forces the user through a manual refresh.
    private func resyncAfterFailedApplyAsync(cause: Error) async throws {
        do {
            let actual = try await bridge.allSnapshots()
            apply(actual)
        } catch let refreshError {
            activationNeedsRefresh = true
            throw WallpaperActionError(message: String(localized: "Could not confirm the display state after applying: \(cause.localizedDescription). Refresh failed: \(refreshError.localizedDescription). Refresh all wallpaper state before retrying."))
        }
    }

    func cancelWallpaperOptionsAsync(wallpaperId: String) async throws {
        await waitForIdleActivation()
        try requireIdleWallpaperEdits(id: wallpaperId)
        applyingWallpaperID = wallpaperId
        defer { applyingWallpaperID = nil; resumeActivationWaiters() }
        desktopPropertyPreviews.cancel(wallpaperId)
        // The bridge puts the saved look back on the displays before it discards the edit, and
        // keeps the edit if a display refuses, so Revert can be asked again.
        let bundle = try await bridge.cancelWallpaperOptions(wallpaperId: wallpaperId)
        forgetPropertyEditsOnDesktop(wallpaperId)
        apply(bundle)
        editorState.discard(wallpaperID: wallpaperId)
        onPropertyDraftChanged?(wallpaperId)
    }

    func pauseAllAsync() async throws {
        let bundle = try await bridge.pauseAll()
        apply(bundle)
    }

    func playAllAsync() async throws {
        let bundle = try await bridge.playAll()
        apply(bundle)
    }

    func setPresentationSuspendedAsync(_ suspended: Bool) async throws {
        try await updatePlaybackEnvironment {
            try await bridge.setPresentationSuspended(suspended: suspended)
        }
    }

    func setDisplayPresentationSuspendedAsync(displayID: UInt32, suspended: Bool) async throws {
        try await updatePlaybackEnvironment {
            try await bridge.setDisplayPresentationSuspended(
                displayId: String(displayID), suspended: suspended)
        }
    }

    /// Sets which wallpapers a display keeps loaded and paused when it moves on to another one,
    /// so one that comes back runs on from where it stopped. An empty list frees them all.
    /// Waits for an Apply in flight, like every playback-environment change.
    func setDisplayParkedWallpapersAsync(displayID: UInt32, wallpaperIDs: [String]) async throws {
        try await updatePlaybackEnvironment {
            try await bridge.setDisplayParkedWallpapers(displayId: String(displayID), wallpaperIds: wallpaperIDs)
        }
    }

    /// The window of every open scene wallpaper, live and kept paused, read without a round trip.
    func sceneWindows() -> [BridgeSceneWindow] {
        bridge.sceneWindows()
    }

    /// Turns renderer work counting on or off. Off by default; the renderer
    /// performs no bookkeeping until this is on, and nothing is pushed back —
    /// counters are only ever read by `rendererCountersAsync`.
    func setRendererCountersEnabledAsync(_ enabled: Bool) async throws {
        try await bridge.setRendererCountersEnabled(enabled: enabled)
    }

    func rendererCountersAsync() async throws -> BridgeRendererCountersReport {
        try await bridge.rendererCounters()
    }

    /// Has the renderer confirm that every scene which should be drawing still is,
    /// and rebuild the surface of any that is not. Waits a few seconds inside the
    /// bridge; it takes none of the store's lanes, so a command is never held up
    /// behind it. The caller decides when the check is safe to start.
    func revalidateScenePresentationAsync(reason: String) async throws -> [BridgeSurfaceCheck] {
        try await bridge.revalidateScenePresentation(reason: reason)
    }

    func ejectWallpaperFromDisplayAsync(
        displayId: String,
        wallpaperId: String
    ) async throws {
        await waitForIdleActivation()
        let bundle = try await bridge.ejectWallpaperFromDisplay(displayId: displayId, wallpaperId: wallpaperId)
        apply(bundle)
    }

    /// The user's **Eject** and **Remove from display**: takes the wallpaper off the display and
    /// tells `onUserWallpaperRemoved`, so a playlist does not fill the display again. A removal
    /// that left something on the display (it showed another wallpaper by then) is not reported.
    func removeWallpaperFromDisplayAsync(displayId: String, wallpaperId: String) async throws {
        try await ejectWallpaperFromDisplayAsync(displayId: displayId, wallpaperId: wallpaperId)
        if shownWallpaperID(on: displayId) == nil { onUserWallpaperRemoved?(wallpaperId, displayId) }
    }

    /// Removes whatever `displayId` shows, as **Remove from display** does, for a caller that
    /// does not know the wallpaper (the menu bar). It takes the display's turn in the command
    /// queue, so a switch asked for before it finishes first and the wallpaper removed is the
    /// one on the display when the turn comes; a display that is empty by then stays as it is.
    func removeShownWallpaperAsync(displayId: String) async throws {
        try await commands.run(slot: Self.activationSlot(displayId: displayId)) {
            try validateActivationTarget(displayId)
            guard let id = shownWallpaperID(on: displayId) else { return }
            try await removeWallpaperFromDisplayAsync(displayId: displayId, wallpaperId: id)
        }
    }

    /// Changes `displayId` to a random wallpaper of `pool` other than the one it shows, as
    /// **Random Wallpaper** does. The pick is made when the display's turn in the command queue
    /// comes, so it is measured from what the display shows then, and it is the user's own
    /// choice (a playlist gives way to it, and it is a manual choice for the rotation's grace).
    /// `playlists` remembers the pick only once it has been shown, so a pick that failed to
    /// apply takes nothing out of the round. Throws when the pool holds no other wallpaper.
    func activateRandomWallpaperAsync(
        displayId: String, pool: AutomationCommand.RandomPool, favorites: Set<String>, playlists: PlaylistStore
    ) async throws {
        try await commands.run(slot: Self.activationSlot(displayId: displayId)) {
            try validateActivationTarget(displayId)
            let candidates = pool.candidates(
                library: librarySnapshot.wallpapers.filter(\.supported).map(\.id),
                favorites: favorites, held: Set(heldWallpaperIDs))
            guard let id = playlists.randomPick(
                on: displayId, pool: pool, from: candidates, after: shownWallpaperID(on: displayId))
            else {
                throw WallpaperActionError(message: String(localized: "There is no other wallpaper to choose from."))
            }
            try await activateWallpaperAsync(id: id, displayId: displayId, origin: .user)
            playlists.recordRandomPick(id, on: displayId, pool: pool, candidates: candidates)
        }
    }

    /// The wallpaper `displayId` shows of its own, nil when it is empty or mirrors another display
    /// (a mirror holds no assignment of its own).
    func shownWallpaperID(on displayId: String) -> String? {
        monitorInformationSnapshot.rows.first {
            $0.displayId == displayId && $0.mirrorTargetDisplayId == nil && !$0.wallpaperId.isEmpty
        }?.wallpaperId
    }

    func shutdownAsync() async throws {
        try await bridge.shutdown()
    }

    func clearShaderCacheAsync() async throws {
        settingsSnapshot = try await bridge.clearShaderCache()
        finishSnapshotApply()
    }

    func clearLogsAsync() throws {
        let status = try bridge.clearLogs()
        settingsSnapshot.storage = BridgeStorageStatus(
            shaderCacheSizeBytes: settingsSnapshot.storage.shaderCacheSizeBytes,
            logs: status
        )
        finishSnapshotApply()
    }

    func logFolderURL() throws -> URL {
        URL(fileURLWithPath: try bridge.logFolderPath(), isDirectory: true)
    }

    private struct Snapshots {
        let app: BridgeAppSnapshot
        let library: BridgeLibrarySnapshot
        let wallpaperOptions: BridgeWallpaperOptionsSnapshot?
        let monitorInformation: BridgeMonitorInformationSnapshot
        let settings: BridgeSettingsSnapshot
    }

    private static func emptySnapshots() -> Snapshots {
        let app = BridgeAppSnapshot(
            playbackState: .paused, selectedWallpaperId: nil, activeWallpaperIds: [], errors: [], heldWallpaperIds: [])
        let library = BridgeLibrarySnapshot(
            wallpapers: [], scanStatus: BridgeLibraryScanStatus(scanning: false, done: 0, total: 0),
            sceneCount: 0, videoCount: 0, webpageCount: 0, unknownCount: 0)
        let monitor = BridgeMonitorInformationSnapshot(rows: [])
        let settings = BridgeSettingsSnapshot(
            displays: [], launchAtLoginAvailable: false, launchAtLoginEnabled: false,
            launchAtLoginNeedsApproval: false, batteryMode: .keepRunning, verboseLogging: false,
            gitSha: "", bridgeVersion: "", coreVersion: "", shaderPipelineVersion: "",
            storage: BridgeStorageStatus(
                shaderCacheSizeBytes: 0,
                logs: BridgeLogStatus(logsRoot: "", activeSession: "", activeFile: "", activeFileSizeBytes: 0)),
            videoBackends: [], sceneOptimizationEnabled: true, sceneOnDemandEnabled: false,
            sceneVideoPlaneSamplingEnabled: false, sceneResolution: "display", sceneUpdateModes: [],
            sceneRenderers: [], userAssetsPath: "", renderScale: 1, preferredRenderScale: 1,
            frameRateCap: nil, batteryRenderScale: 0.75, batteryTargetFps: 30, onBatteryPower: false,
            qualityThrottle: [], effectiveFrameRateCap: nil, renderScaleSupported: false)
        return Snapshots(app: app, library: library, wallpaperOptions: nil, monitorInformation: monitor, settings: settings)
    }

    private func apply(_ bundle: BridgeSnapshotBundle) {
        self.appSnapshot = bundle.app
        self.librarySnapshot = bundle.library
        self.wallpaperOptionsSnapshot = bundle.wallpaperOptions
        self.monitorInformationSnapshot = bundle.monitorInformation
        self.settingsSnapshot = bundle.settings
        finishSnapshotApply()
    }

    private func apply(_ bundle: BridgeWallpaperMutationBundle) {
        self.appSnapshot = bundle.app
        self.librarySnapshot = bundle.library
        self.wallpaperOptionsSnapshot = bundle.wallpaperOptions
        self.monitorInformationSnapshot = bundle.monitorInformation
        self.settingsSnapshot = bundle.settings
        finishSnapshotApply()
    }

    private func apply(_ bundle: BridgeDisplayMutationBundle) {
        self.appSnapshot = bundle.app
        self.librarySnapshot = bundle.library
        self.monitorInformationSnapshot = bundle.monitorInformation
        self.settingsSnapshot = bundle.settings
        finishSnapshotApply()
    }

    private func finishSnapshotApply() {
        if let options = wallpaperOptionsSnapshot {
            // Drafts for properties that no longer take text are stale.
            let textProperties = Set(options.properties.filter { $0.kind == .textInput && $0.enabled }.map(\.id))
            editorState.reconcile(wallpaperID: options.wallpaperId, textPropertyIDs: textProperties)
            // The inspector moved on to this wallpaper, so a drag left on another is over: that
            // wallpaper's displays follow its draft again.
            for other in editorState.clearPropertyPreviews(except: options.wallpaperId).sorted() {
                propertyDraftEdited(other)
            }
        }
        snapshotRevision &+= 1
        onSnapshotApplied?()
        if let newest = appSnapshot.errors.last, newest != latestBridgeErrorMessage {
            latestBridgeErrorMessage = newest
            latestBridgeErrorRevision &+= 1
        }
    }
}

extension QualityReduction {
    /// The reason the bridge is told about.
    var bridgeCause: BridgeQualityThrottleCause {
        switch self {
        case .heat: .heat
        case .lowPowerMode: .lowPowerMode
        case .lowBattery: .lowBattery
        }
    }
}
