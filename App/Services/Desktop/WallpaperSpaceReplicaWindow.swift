import AppKit

/// A static, single-Space backing picture. Deliberately outside the live wallpaper class list:
/// it has no renderer, input, audio, poster ownership or effect on presentation suspension.
@MainActor
final class WallpaperSpaceReplicaWindow: NSWindow, WallpaperSpaceReplicaSurface {
    private let picture = CALayer()
    private var shownImage: CGImage?

    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        collectionBehavior = [.stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = true; hasShadow = false; isMovable = false; isRestorable = false
        ignoresMouseEvents = true; hidesOnDeactivate = false; canHide = false
        isExcludedFromWindowsMenu = true; animationBehavior = .none
        backgroundColor = .black
        picture.contentsGravity = .resize
        picture.isOpaque = true
        picture.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        let view = NSView(frame: CGRect(origin: .zero, size: frame.size))
        view.layer = picture
        view.wantsLayer = true
        contentView = view
    }

    var number: Int { windowNumber }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    func setImage(_ image: CGImage, frame: CGRect) {
        if self.frame != frame { setFrame(frame, display: false) }
        guard shownImage !== image else { return }
        shownImage = image
        picture.contents = image
    }

    func present(below window: Int) {
        CATransaction.flush()
        order(.below, relativeTo: window)
    }

    override func close() {
        orderOut(nil)
        picture.contents = nil
        shownImage = nil
        super.close()
    }
}
