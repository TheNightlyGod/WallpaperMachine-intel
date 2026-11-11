import AppKit

/// What `DesktopWidgetController` puts a widget on: a window in production, a recorder in tests.
@MainActor
protocol DesktopWidgetSurface: AnyObject {
    /// Shows `drawing` with `padding` around it, in `frame` (global screen coordinates).
    func show(_ drawing: DesktopWidgetRendering.Drawing, padding: CGFloat, frame: NSRect)
    /// Whether any of it can be seen now: false while windows cover it, the display sleeps or the
    /// screen is locked.
    var isOnScreen: Bool { get }
    func remove()
}

/// One desktop widget's window: transparent, the size of its text or clock face, just above the wallpaper windows
/// and below Finder's desktop icons, on every Space, ignoring the mouse. Its Objective-C name is not
/// one of `WallpaperPresentationPolicy.wallpaperWindowClassNames`, so occlusion tracking, the
/// window audit and the desktop-picture posters never take it for a wallpaper.
@objc(MWEDesktopWidgetWindow)
final class DesktopWidgetWindow: NSWindow, DesktopWidgetSurface {
    private let widgetView = DesktopWidgetView()

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// A widget may sit under the menu bar, out of which AppKit would otherwise move a window.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    /// A widget window that is not yet on screen.
    static func make() -> DesktopWidgetWindow {
        let window = DesktopWidgetWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1), styleMask: .borderless,
            backing: .buffered, defer: false)
        // Just above the wallpaper windows, as the coverage probes and the notch strip are, and below
        // Finder's icons. Being transparent and smaller than a display's working area, it never
        // makes a display count as covered.
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isMovable = false
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        // Hiding the app hides the panel, never the desktop.
        window.canHide = false
        window.hidesOnDeactivate = false
        window.isExcludedFromWindowsMenu = true
        window.animationBehavior = .none
        window.contentView = window.widgetView
        return window
    }

    /// A widget window, put on screen.
    static func present() -> any DesktopWidgetSurface {
        let window = make()
        window.orderFrontRegardless()
        return window
    }

    func show(_ drawing: DesktopWidgetRendering.Drawing, padding: CGFloat, frame: NSRect) {
        if self.frame != frame { setFrame(frame, display: false) }
        widgetView.update(drawing: drawing, padding: padding)
    }

    var isOnScreen: Bool { occlusionState.contains(.visible) }

    func remove() {
        orderOut(nil)
        close()
    }

    /// The words the window shows; empty for a clock face.
    var shownText: String {
        if case .text(let text) = widgetView.drawing { return text.string }
        return ""
    }
}

/// Draws a widget's text or clock face, and redraws only when it changes: on the desktop, and in
/// the panel's preview, which so draws it the same way. It never takes the mouse; the preview's drag
/// is the panel's own.
final class DesktopWidgetView: NSView {
    private(set) var drawing = DesktopWidgetRendering.Drawing.text(NSAttributedString())
    private var padding: CGFloat = 0

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(drawing: DesktopWidgetRendering.Drawing, padding: CGFloat) {
        guard drawing != self.drawing || padding != self.padding else { return }
        self.drawing = drawing
        self.padding = padding
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let content = bounds.insetBy(dx: padding, dy: padding)
        switch drawing {
        case .text(let text):
            // Laid out from the top, so a widget cut to its display keeps its first lines.
            text.draw(with: content, options: [.usesLineFragmentOrigin, .usesFontLeading])
        case .analog(let face):
            Self.draw(face, in: content)
        }
    }

    /// A ring, twelve hour marks (the quarters longer), the hands and a dot at the centre, drawn
    /// as one layer so the hands crossing neither darken nor cast a shadow on each other.
    private static func draw(_ face: DesktopWidgetRendering.AnalogFace, in rect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let context = NSGraphicsContext.current?.cgContext
        if let shadow = face.shadow {
            let value = NSShadow()
            value.shadowBlurRadius = shadow.blur
            value.shadowOffset = NSSize(width: 0, height: -shadow.offset)
            value.shadowColor = NSColor.black.withAlphaComponent(0.45)
            value.set()
        }
        context?.setAlpha(face.color.alphaComponent)
        context?.beginTransparencyLayer(auxiliaryInfo: nil)
        defer { context?.endTransparencyLayer() }
        face.color.withAlphaComponent(1).set()
        let radius = min(rect.width, rect.height) / 2
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let width = face.lineWidth
        func point(_ turn: Double, _ length: CGFloat) -> NSPoint {
            let angle = turn * 2 * .pi
            return NSPoint(x: center.x + CGFloat(sin(angle)) * length, y: center.y + CGFloat(cos(angle)) * length)
        }
        func line(from start: NSPoint, to end: NSPoint, width: CGFloat) {
            let path = NSBezierPath()
            path.move(to: start)
            path.line(to: end)
            path.lineWidth = width
            path.lineCapStyle = .round
            path.stroke()
        }
        let ringWidth = max(width * 0.5, 0.5)
        let ring = NSBezierPath(
            ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius)
                .insetBy(dx: ringWidth / 2, dy: ringWidth / 2))
        ring.lineWidth = ringWidth
        ring.stroke()
        for mark in 0..<12 {
            let turn = Double(mark) / 12
            let length = radius * (mark % 3 == 0 ? 0.14 : 0.08)
            let outer = radius - ringWidth - radius * 0.04
            line(from: point(turn, outer), to: point(turn, outer - length), width: width * (mark % 3 == 0 ? 0.9 : 0.6))
        }
        line(from: center, to: point(face.hour, radius * 0.5), width: width * 1.6)
        line(from: center, to: point(face.minute, radius * 0.76), width: width)
        if let second = face.second {
            line(from: point(second + 0.5, radius * 0.12), to: point(second, radius * 0.84), width: max(width * 0.35, 0.5))
        }
        let dot = width * 1.3
        NSBezierPath(ovalIn: NSRect(x: center.x - dot, y: center.y - dot, width: 2 * dot, height: 2 * dot)).fill()
    }
}
