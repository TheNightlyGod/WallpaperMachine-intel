import AppKit

/// Builds the control-panel window and owns its size floor.
///
/// `contentMinSize` alone does not hold: once the SwiftUI hosting controller attaches, it
/// resets the window's content minimum to zero even with `sizingOptions = []`, so the
/// window delegate clamps every user resize through `clampedFrameSize` instead.
///
/// The window carries no chrome of its own. The hosted page's `.toolbar` (the tabs and the
/// trailing tools) and `.navigationTitle` reach the window through the hosting controller's
/// `sceneBridgingOptions`; a manually assigned `NSToolbar` would fight them.
@MainActor
enum ControlPanelWindow {
    /// Smallest content area the panel lays out without clipping; the layout tests use it too.
    static let minimumContentSize = NSSize(width: 760, height: 560)
    static let initialContentSize = NSSize(width: 1240, height: 800)
    static let frameAutosaveName = "WallpaperMachineMainWindow"

    static func make(contentViewController: NSViewController, delegate: NSWindowDelegate?) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: initialContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "WallpaperMachine"
        window.delegate = delegate
        window.isReleasedWhenClosed = false
        window.contentViewController = contentViewController
        // Attaching a controller sizes the window to its view, which a hosting controller with
        // `sizingOptions = []` has not laid out yet.
        window.setContentSize(initialContentSize)
        window.contentMinSize = minimumContentSize
        moveToActiveSpace(window)
        return window
    }

    /// Makes an ordinary window appear on the Space that is active when it is shown, instead
    /// of switching the person back to the Space it was last left on. For the control panel,
    /// What's New, preview and sign-in windows; wallpaper, overlay and probe windows keep
    /// their all-Spaces behavior.
    ///
    /// Flags are inserted and removed, never assigned, so the full-screen capability and the
    /// window-cycle flags a window already has survive. `.canJoinAllSpaces` leaves because AppKit
    /// raises when it meets `.moveToActiveSpace`.
    static func moveToActiveSpace(_ window: NSWindow) {
        var behavior = window.collectionBehavior
        behavior.subtract([.managed, .canJoinAllSpaces])
        behavior.insert(.moveToActiveSpace)
        window.collectionBehavior = behavior
    }

    /// Fronts a window, bringing it back from the Dock first when it is minimized, which
    /// `makeKeyAndOrderFront` alone does not do.
    ///
    /// `makeKeyAndOrderFront` only fronts the window among the app's own windows while the app
    /// is inactive, and macOS may decline the activation that follows: after an update the
    /// helper's `open` relaunches the app while another app is active, so What's New and the
    /// panel opened behind it, reachable only through Mission Control. `orderFrontRegardless`
    /// puts the window above the active app either way; it becomes key once the app activates.
    static func bringForward(_ window: NSWindow) {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    /// The frame size the window may not shrink below: the minimum content size plus
    /// window chrome, capped by the visible frame of the screen it is on.
    static func minimumFrameSize(for window: NSWindow) -> NSSize {
        let minimumFrame = window.frameRect(forContentRect: NSRect(origin: .zero, size: minimumContentSize))
        guard let visible = visibleFrame(for: window) else { return minimumFrame.size }
        return NSSize(width: min(minimumFrame.width, visible.width),
                      height: min(minimumFrame.height, visible.height))
    }

    /// Clamps a proposed frame size to the size floor; used from `windowWillResize`.
    static func clampedFrameSize(_ proposed: NSSize, for window: NSWindow) -> NSSize {
        let minimum = minimumFrameSize(for: window)
        return NSSize(width: max(proposed.width, minimum.width),
                      height: max(proposed.height, minimum.height))
    }

    /// Re-asserts the size floor and keeps the whole frame on the visible screen.
    static func constrainToScreen(_ window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen), let visible = visibleFrame(for: window) else { return }
        let minimumSize = minimumFrameSize(for: window)
        window.contentMinSize = window.contentRect(forFrameRect: NSRect(origin: .zero, size: minimumSize)).size
        var frame = window.frame
        frame.size.width = min(max(frame.width, minimumSize.width), visible.width)
        frame.size.height = min(max(frame.height, minimumSize.height), visible.height)
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        if frame != window.frame { window.setFrame(frame, display: false) }
    }

    private static func visibleFrame(for window: NSWindow) -> NSRect? {
        (window.screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
    }
}
