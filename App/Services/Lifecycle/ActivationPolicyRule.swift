/// Whether the app keeps its Dock icon and menu bar (`.regular`) or lives in the status item
/// alone (`.accessory`).
///
/// The app is regular while one of its own ordinary windows is open, on screen or minimized
/// to the Dock. Every place that lowers the policy asks this one rule; whatever opens a window
/// raises the policy itself. Pure, so it is tested without AppKit.
enum ActivationPolicyRule {
    /// One of the app's windows, as the rule sees it.
    struct Window: Equatable, Sendable {
        enum Role: Sendable {
            case controlPanel, whatsNew, preview, signIn
        }

        /// Nil for every other window: an alert, an open or save panel, the status item's, a
        /// wallpaper's borderless desktop window. Those never keep the Dock icon.
        var role: Role?
        var isVisible: Bool
        var isMiniaturized: Bool
    }

    /// True while an ordinary window is on screen or in the Dock. One that is ordered out, as
    /// a quit leaves the panel and What's New, no longer counts. While a quit runs, those two
    /// are put away (only a refused quit brings them back, and raises the policy itself), so
    /// they do not count whatever AppKit still reports for a minimized one.
    static func keepsRegular(_ windows: [Window], quitting: Bool) -> Bool {
        windows.contains { window in
            guard let role = window.role, window.isVisible || window.isMiniaturized else { return false }
            switch role {
            case .controlPanel, .whatsNew: return !quitting
            case .preview, .signIn: return true
            }
        }
    }
}
