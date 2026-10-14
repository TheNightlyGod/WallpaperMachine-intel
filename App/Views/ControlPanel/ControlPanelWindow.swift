import AppKit

/// Builds the control-panel window and owns its size floor.
///
/// `contentMinSize` alone does not hold: once the SwiftUI hosting controller attaches, it
/// resets the window's content minimum to zero even with `sizingOptions = []`, so the
/// window delegate clamps every user resize through `clampedFrameSize` instead.
@MainActor
enum ControlPanelWindow {
    /// Smallest content area the bundled panel lays out without overflow; the web page's
    /// `body` min-width and the panel layout tests use the same figure.
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
        // In windowed mode, the page draws its top bar in the title-bar strip. An empty
        // unified toolbar aligns the traffic lights with the tabs; the page reads their
        // inset from the snapshot and handles dragging itself.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        let titlebarSpacer = NSToolbar(identifier: "WallpaperMachineTitlebar")
        titlebarSpacer.showsBaselineSeparator = false
        window.toolbar = titlebarSpacer
        window.delegate = delegate
        window.isReleasedWhenClosed = false
        window.contentViewController = PanelContentController(hosted: contentViewController)
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
    /// window-cycle flags a window already has survive (`windowDidEnterFullScreen` relies on
    /// them). `.canJoinAllSpaces` leaves because AppKit raises when it meets
    /// `.moveToActiveSpace`.
    static func moveToActiveSpace(_ window: NSWindow) {
        var behavior = window.collectionBehavior
        behavior.subtract([.managed, .canJoinAllSpaces])
        behavior.insert(.moveToActiveSpace)
        window.collectionBehavior = behavior
    }

    /// Fronts a window, bringing it back from the Dock first when it is minimized, which
    /// `makeKeyAndOrderFront` alone does not do.
    static func bringForward(_ window: NSWindow) {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    /// Keeps the web navigation out from under AppKit's opaque full-screen title bar,
    /// including in Split View. Apply after a completed transition so cancellation
    /// leaves the previous layout intact.
    static func setFullScreenLayout(_ isFullScreen: Bool, for window: NSWindow) {
        let frame = window.frame
        if isFullScreen {
            window.toolbar?.isVisible = false
            window.styleMask.remove(.fullSizeContentView)
        } else {
            window.styleMask.insert(.fullSizeContentView)
            window.toolbar?.isVisible = true
        }
        // Changing fullSizeContentView otherwise resizes the frame to preserve content
        // height, which would move it outside its full-screen tile or restored bounds.
        if window.frame != frame { window.setFrame(frame, display: false) }
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

/// Keep the window's content coordinates unflipped while SwiftUI and WebKit retain
/// their own coordinate systems. WebKit's native color popover uses a window-space
/// rect as a content-view frame (https://bugs.webkit.org/show_bug.cgi?id=300025).
@MainActor
private final class PanelContentController: NSViewController {
    init(hosted: NSViewController) {
        super.init(nibName: nil, bundle: nil)
        view = NSView(frame: NSRect(origin: .zero, size: ControlPanelWindow.initialContentSize))
        addChild(hosted)
        let hostedView = hosted.view
        hostedView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hostedView)
        NSLayoutConstraint.activate([
            hostedView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostedView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostedView.topAnchor.constraint(equalTo: view.topAnchor),
            hostedView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
