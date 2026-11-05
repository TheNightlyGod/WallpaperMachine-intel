import AppKit

/// Invisible window just above the wallpaper whose occlusion tells whether other
/// windows cover a display's working area.
@objc(MWEWallpaperCoverageProbeWindow)
final class WallpaperCoverageProbeWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Tells which displays have their working area covered by other windows.
///
/// AppKit reports a wallpaper window visible while any pixel of it shows, and
/// the strip under the translucent menu bar and a zoomed window's rounded
/// corners always show. So one probe per display covers that display's
/// `visibleFrame` (the screen minus the menu bar and a shown Dock) inset by
/// `edgeMargin`, and the display counts as covered once AppKit reports the
/// probe occluded. The probe is fully transparent and ignores the mouse, so a
/// click on the desktop still reaches Finder. Its occlusion changes post
/// `NSWindow.didChangeOcclusionStateNotification`, which the presentation
/// policy already observes, so nothing polls. `AppRuleMonitor` observes the same
/// changes to notice the app in front minimizing or closing the window over the desktop.
@MainActor
final class WallpaperCoverageProbes {
    /// Wide enough for the rounded corners of a zoomed window and the margins
    /// macOS leaves around tiled windows at the screen edges.
    static let edgeMargin: CGFloat = 32

    private var probes: [UInt32: WallpaperCoverageProbeWindow] = [:]

    /// Places, moves or removes probes so each connected display has one.
    func sync() {
        var seen: Set<UInt32> = []
        for screen in NSScreen.screens {
            guard let displayID = SystemDisplays.id(of: screen),
                  let frame = Self.probeFrame(for: screen.visibleFrame) else { continue }
            seen.insert(displayID)
            if let probe = probes[displayID] {
                if probe.frame != frame { probe.setFrame(frame, display: false) }
            } else {
                probes[displayID] = Self.makeProbe(frame: frame)
            }
        }
        for (displayID, probe) in probes where !seen.contains(displayID) {
            probe.orderOut(nil)
            probe.close()
            probes[displayID] = nil
        }
    }

    func removeAll() {
        for probe in probes.values {
            probe.orderOut(nil)
            probe.close()
        }
        probes.removeAll()
    }

    /// Displays whose probe AppKit reports hidden. A display without a probe is
    /// never reported covered.
    func coveredDisplayIDs() -> Set<UInt32> {
        Set(probes.filter { !$0.value.occlusionState.contains(.visible) }.map(\.key))
    }

    /// The working area inset by `edgeMargin`, or nil when nothing would remain.
    static func probeFrame(for visibleFrame: NSRect, margin: CGFloat = edgeMargin) -> NSRect? {
        let frame = visibleFrame.insetBy(dx: margin, dy: margin)
        return frame.width > 0 && frame.height > 0 ? frame : nil
    }

    private static func makeProbe(frame: NSRect) -> WallpaperCoverageProbeWindow {
        let probe = WallpaperCoverageProbeWindow(
            contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        // Just above the wallpaper windows and below Finder's desktop icons.
        probe.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        probe.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        probe.isOpaque = false
        probe.backgroundColor = .clear
        probe.alphaValue = 0
        probe.hasShadow = false
        probe.ignoresMouseEvents = true
        probe.isReleasedWhenClosed = false
        probe.isRestorable = false
        probe.canHide = false
        probe.hidesOnDeactivate = false
        probe.isExcludedFromWindowsMenu = true
        probe.animationBehavior = .none
        probe.orderFrontRegardless()
        return probe
    }
}
