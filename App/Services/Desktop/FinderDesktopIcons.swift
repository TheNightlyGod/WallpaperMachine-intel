import AppKit

/// Finder's own choice to show icons on the desktop, `com.apple.finder CreateDesktop`, which
/// Finder reads when it starts. Off, the desktop shows no files, folders or disks, so nothing
/// covers the wallpaper; the files stay in the Desktop folder.
///
/// The app changes it only when the user asks (the status menu's Hide Desktop Icons and
/// Settings › Desktop & Lock Screen), and then restarts Finder so the desktop follows. It never
/// keeps its own copy: every reading asks macOS again, so a change made in Terminal shows too.
/// Everything that touches Finder goes through `DesktopActions`, so a test never changes or
/// restarts the developer's Finder.
@MainActor
struct FinderDesktopIcons {
    nonisolated static let bundleIdentifier = "com.apple.finder"
    nonisolated static let key = "CreateDesktop"
    /// How long Finder has to come back by itself before the app opens it.
    nonisolated static let relaunchCheckDelay: TimeInterval = 5

    struct WriteRefused: LocalizedError {
        var errorDescription: String? {
            String(localized: "macOS did not accept the change to Finder’s desktop icons.")
        }
    }

    /// The choice is stored, but the running Finder could not be ended, so it keeps showing the
    /// desktop as it was until it next starts.
    struct RestartFailed: LocalizedError {
        var errorDescription: String? {
            String(localized: "Finder could not be restarted, so the desktop icons change the next time Finder starts.")
        }
    }

    private let desktop: DesktopActions

    /// Nil is `DesktopActions.current`, read here because a default argument cannot reach it.
    init(desktop: DesktopActions? = nil) {
        self.desktop = desktop ?? .current
    }

    /// Whether Finder shows icons on the desktop, or will once it next starts.
    var areShown: Bool {
        Self.areShown(storedValue: desktop.finderDesktopPreference())
    }

    /// Stores the choice and restarts Finder so the desktop follows it. Nothing happens, and false
    /// is returned, when Finder already has that choice. Throws `WriteRefused`, leaving Finder
    /// running as it was, when macOS does not accept the preference, and `RestartFailed` when the
    /// running Finder could not be ended: the choice is stored then and applies when Finder next
    /// starts.
    @discardableResult
    func setShown(_ shown: Bool) throws -> Bool {
        guard shown != areShown else { return false }
        guard desktop.setFinderDesktopPreference(shown) else {
            AppLog.warn("desktop icons: macOS refused \(Self.bundleIdentifier) \(Self.key) = \(shown)")
            throw WriteRefused()
        }
        AppLog.info("desktop icons: Finder \(shown ? "shows" : "hides") them from now on; restarting Finder")
        guard desktop.restartFinder() else { throw RestartFailed() }
        return true
    }

    /// What a stored value means, read the way a Cocoa app reads a switch from its preferences: a
    /// boolean or a number is itself; a string, which `defaults write` stores when given no type,
    /// is on for `true` or `yes` in any case and off for `false` or `no`, and otherwise on only as
    /// a whole number other than 0. Nothing stored, or a value of another kind, is Finder's
    /// default: shown.
    nonisolated static func areShown(storedValue: Any?) -> Bool {
        switch storedValue {
        case let number as NSNumber:
            return number.boolValue
        case let text as String:
            switch text.trimmingCharacters(in: .whitespaces).lowercased() {
            case "true", "yes": return true
            case "false", "no": return false
            case let other: return (Int(other) ?? 0) != 0
            }
        default:
            return true
        }
    }

    // MARK: The live Finder (`DesktopActions.live`)

    static func readSystemPreference() -> Any? {
        CFPreferencesCopyAppValue(key as CFString, bundleIdentifier as CFString)
    }

    /// Writes the same boolean `defaults write com.apple.finder CreateDesktop -bool` writes.
    static func writeSystemPreference(shown: Bool) -> Bool {
        let domain = bundleIdentifier as CFString
        CFPreferencesSetAppValue(key as CFString, shown ? kCFBooleanTrue : kCFBooleanFalse, domain)
        return CFPreferencesAppSynchronize(domain)
    }

    /// Ends Finder the way `killall Finder` does, after which macOS starts it again. An ordinary
    /// quit would leave Finder, and the desktop with it, closed until the user opens it, so if no
    /// Finder runs a few seconds later the app opens one itself, without bringing it forward.
    /// False when a running Finder could not be ended. With no Finder running there is nothing to
    /// restart: the choice applies when the user next opens Finder, and the app does not open it.
    static func restartSystemFinder() -> Bool {
        restart(
            finders: NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
                .map(\.processIdentifier),
            end: { kill($0, SIGTERM) == 0 ? 0 : errno },
            checkBackLater: {
                DispatchQueue.main.asyncAfter(deadline: .now() + relaunchCheckDelay) { openFinderIfGone() }
            })
    }

    /// The restart's decisions, apart from the processes it acts on: `end` sends one Finder its
    /// signal and answers 0 or the `errno` of a failure, and `checkBackLater` runs once when at
    /// least one Finder was ended, never when none was running. A Finder that had already quit
    /// (`ESRCH`) counts as ended; any other failure makes the restart fail.
    nonisolated static func restart(
        finders: [pid_t], end: (pid_t) -> Int32, checkBackLater: () -> Void
    ) -> Bool {
        if finders.isEmpty {
            AppLog.info("desktop icons: Finder is not running; the choice applies when it next starts")
        }
        var ended = false
        var failed = false
        for finder in finders {
            let error = end(finder)
            if error == 0 || error == ESRCH {
                ended = true
            } else {
                failed = true
                AppLog.warn("desktop icons: could not end Finder (pid \(finder)): errno \(error)")
            }
        }
        if ended { checkBackLater() }
        return !failed
    }

    nonisolated private static func openFinderIfGone() {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        else { return }
        AppLog.info("desktop icons: Finder did not come back by itself; opening it")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error { AppLog.error("desktop icons: Finder could not be opened: \(error.localizedDescription)") }
        }
    }
}
