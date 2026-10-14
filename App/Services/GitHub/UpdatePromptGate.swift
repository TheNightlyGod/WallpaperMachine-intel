import Foundation

/// Decides whether the unattended update alert may appear right now. The alert is modal and
/// brings the app to the front, so it must not interrupt someone watching a full-screen app,
/// a locked screen or a sleeping display: those are exactly the moments the wallpaper
/// presentation is suspended. The decision is a pure function of the app's own signals, so
/// the table is testable without a desktop.
enum UpdatePromptGate {
    struct Input: Equatable, Sendable {
        /// The control panel is on screen and is the key window, so the person is in our app.
        var panelVisibleAndActive: Bool
        /// Display sleep, a locked session, app rules and the Focus filter action.
        var globalPresentation: GlobalPresentation
        /// A display whose wallpaper is fully hidden, which is what a full-screen app does.
        var hasSuspendedDisplay: Bool
        var whatsNewOpen: Bool
        var shuttingDown: Bool
    }

    enum HoldReason: String, Equatable, Sendable {
        case shuttingDown
        case whatsNewOpen
        case presentationSuspended
        case displayCovered
    }

    enum Decision: Equatable, Sendable {
        case present
        case hold(HoldReason)
    }

    static func decide(_ input: Input) -> Decision {
        if input.shuttingDown { return .hold(.shuttingDown) }
        if input.whatsNewOpen { return .hold(.whatsNewOpen) }
        // Someone already working in the panel is the one place an alert is welcome, even
        // while wallpapers are paused by a rule.
        if input.panelVisibleAndActive { return .present }
        if input.globalPresentation != .running { return .hold(.presentationSuspended) }
        if input.hasSuspendedDisplay { return .hold(.displayCovered) }
        return .present
    }
}

/// Remembers which version the alert has been shown for and whether a prompt is waiting for
/// the gate to open. A held prompt never counts as offered, so it appears once when the
/// gate opens, and a version the person dismissed with Later stays dismissed for the launch.
struct UpdatePromptLedger: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        /// Nothing to do: no update, or this version was already offered.
        case none
        /// Show the alert for this version; it is now recorded as offered.
        case present(version: String)
        /// Not now. `isNew` is true when this is the first hold or its reason changed, so
        /// callers log a transition rather than every retry.
        case held(UpdatePromptGate.HoldReason, isNew: Bool)
    }

    private(set) var offeredVersion: String?
    /// Why a prompt is waiting, or nil when none is.
    private(set) var holdReason: UpdatePromptGate.HoldReason?

    /// `version` is the update worth an alert (downloaded or available), nil when there is none.
    mutating func offer(version: String?, input: UpdatePromptGate.Input) -> Outcome {
        guard let version, version != offeredVersion else {
            holdReason = nil
            return .none
        }
        switch UpdatePromptGate.decide(input) {
        case .present:
            offeredVersion = version
            holdReason = nil
            return .present(version: version)
        case .hold(let reason):
            let isNew = holdReason != reason
            holdReason = reason
            return .held(reason, isNew: isNew)
        }
    }
}
