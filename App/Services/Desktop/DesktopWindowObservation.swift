import AppKit
import CoreGraphics

/// One wallpaper window as AppKit and the window server describe it at a
/// moment. The two disagree exactly when a wallpaper does not show: AppKit can
/// say a window is ordered in while the window server does not composite it
/// (another Space, a display that went away), so both sides are kept.
struct DesktopWindowObservation: Equatable, Sendable {
    /// What the window server reports for the window number.
    struct WindowServerEntry: Equatable, Sendable {
        var layer: Int
        var alpha: Double
        /// `kCGWindowIsOnscreen`: ordered in and on a Space that is showing.
        var isOnScreen: Bool
        /// In window-server coordinates, whose origin is the top left.
        var bounds: CGRect

        init(layer: Int, alpha: Double, isOnScreen: Bool, bounds: CGRect) {
            self.layer = layer
            self.alpha = alpha
            self.isOnScreen = isOnScreen
            self.bounds = bounds
        }

        /// Reads one description from `CGWindowListCreateDescriptionFromArray`.
        /// The window server leaves `kCGWindowIsOnscreen` out instead of
        /// writing false, so a missing key means the window is not on screen.
        /// Nil when the layer, alpha or bounds are missing or malformed.
        init?(description: [String: Any]) {
            guard let layer = (description[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  let alpha = (description[kCGWindowAlpha as String] as? NSNumber)?.doubleValue,
                  let boundsValue = description[kCGWindowBounds as String],
                  let boundsDictionary = boundsValue as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary)
            else { return nil }
            self.init(
                layer: layer, alpha: alpha,
                isOnScreen: (description[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false,
                bounds: bounds)
        }
    }

    var windowNumber: Int
    var className: String
    /// The display AppKit places the window on; nil when it is on none.
    var displayID: UInt32?
    var frame: CGRect
    var displayFrame: CGRect?
    var level: Int
    var alpha: Double
    /// `NSWindow.isVisible`: ordered in, not necessarily composited.
    var isOrderedIn: Bool
    var isOnActiveSpace: Bool
    var occlusionVisible: Bool
    var collectionBehaviorRaw: UInt
    /// Nil when the window server has no entry for the window number.
    var server: WindowServerEntry?

    var state: DesktopWindowState { DesktopWindowState.classify(self) }
}

/// Why a wallpaper window is, or is not, expected to show. Cases are checked
/// in the order they are declared after `ok`, so one fault is named once: a
/// window that is not ordered in is not also reported as off Space.
///
/// A state is an observation, not a verdict. Inside a full-screen Space the
/// wallpaper windows legitimately report `notOnActiveSpace`; the caller knows
/// whether that is expected.
enum DesktopWindowState: String, Equatable, Sendable {
    case ok
    /// AppKit does not consider the window ordered in.
    case notOrderedIn
    /// Ordered in, but the window server has no entry for the window number.
    case absentFromWindowServer
    /// The window is ordered in on a Space that is not showing.
    case notOnActiveSpace
    /// AppKit says the window is ordered in on the active Space, yet the
    /// window server does not list it on screen.
    case offScreenInWindowServer
    /// The frame does not intersect the display the window belongs to, or the
    /// window is on no display.
    case outsideItsDisplay
    /// The window or the window server's copy of it is not fully opaque.
    case transparent

    static func classify(_ window: DesktopWindowObservation) -> DesktopWindowState {
        guard window.isOrderedIn else { return .notOrderedIn }
        guard let server = window.server else { return .absentFromWindowServer }
        guard window.isOnActiveSpace else { return .notOnActiveSpace }
        guard server.isOnScreen else { return .offScreenInWindowServer }
        guard let display = window.displayFrame, window.frame.intersects(display) else {
            return .outsideItsDisplay
        }
        guard window.alpha >= 1, server.alpha >= 1 else { return .transparent }
        return .ok
    }
}

/// Reads the wallpaper windows the app owns. One window-server call per read,
/// for exactly those window numbers: no window list scan, no polling, and no
/// Screen Recording permission, which only titles and pixels need.
@MainActor
enum DesktopWindowReader {
    static func current(
        windows: [NSWindow]? = nil,
        windowServer: ([Int]) -> [Int: DesktopWindowObservation.WindowServerEntry] = {
            DesktopWindowReader.windowServerEntries(for: $0)
        }
    ) -> [DesktopWindowObservation] {
        let windows = windows ?? WallpaperPresentationPolicy.wallpaperWindows()
        guard !windows.isEmpty else { return [] }
        let entries = windowServer(windows.map(\.windowNumber))
        return windows
            .map { observation(of: $0, server: entries[$0.windowNumber]) }
            .sorted { ($0.displayID ?? .max, $0.windowNumber) < ($1.displayID ?? .max, $1.windowNumber) }
    }

    static func observation(
        of window: NSWindow, server: DesktopWindowObservation.WindowServerEntry?
    ) -> DesktopWindowObservation {
        let screen = window.screen
        return DesktopWindowObservation(
            windowNumber: window.windowNumber,
            className: NSStringFromClass(type(of: window)),
            displayID: screen.flatMap(WallpaperCoverageProbes.displayID(of:)),
            frame: window.frame,
            displayFrame: screen?.frame,
            level: window.level.rawValue,
            alpha: Double(window.alphaValue),
            isOrderedIn: window.isVisible,
            isOnActiveSpace: window.isOnActiveSpace,
            occlusionVisible: window.occlusionState.contains(.visible),
            collectionBehaviorRaw: window.collectionBehavior.rawValue,
            server: server)
    }

    /// What the window server says about the given window numbers, keyed by
    /// number. A window that no longer exists has no entry. Numbers that are
    /// not valid window IDs (AppKit uses -1 for a window with no backing
    /// store yet) are not asked about.
    nonisolated static func windowServerEntries(
        for windowNumbers: [Int]
    ) -> [Int: DesktopWindowObservation.WindowServerEntry] {
        let ids = windowNumbers.filter { $0 > 0 && $0 <= Int(UInt32.max) }
        guard !ids.isEmpty else { return [:] }
        // The array holds the window IDs themselves, not boxed numbers.
        var values: [UnsafeRawPointer?] = ids.map { UnsafeRawPointer(bitPattern: $0) }
        guard let array = CFArrayCreate(nil, &values, values.count, nil),
              let descriptions = CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]]
        else { return [:] }
        var entries: [Int: DesktopWindowObservation.WindowServerEntry] = [:]
        for description in descriptions {
            guard let number = (description[kCGWindowNumber as String] as? NSNumber)?.intValue,
                  let entry = DesktopWindowObservation.WindowServerEntry(description: description)
            else { continue }
            entries[number] = entry
        }
        return entries
    }
}
