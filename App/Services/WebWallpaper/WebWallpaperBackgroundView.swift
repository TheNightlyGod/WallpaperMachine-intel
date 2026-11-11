import AppKit
import Metal
import QuartzCore

/// A stable black backing for the web view and its suspension poster.
/// A submitted Metal surface keeps this desktop window live during Stage
/// Manager transitions; an empty CAMetalLayer still freezes on macOS 27.
@MainActor
final class WebWallpaperBackgroundView: NSView {
    private static let defaultDevice = MTLCreateSystemDefaultDevice()
    private let device: MTLDevice?

    override convenience init(frame: NSRect) {
        self.init(frame: frame, device: Self.defaultDevice)
    }

    init(frame: NSRect, device: MTLDevice?) {
        self.device = device
        super.init(frame: frame)
        layerContentsRedrawPolicy = .never
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }

    override func makeBackingLayer() -> CALayer {
        guard let device else {
            AppLog.warn("web wallpaper: Metal background is unavailable")
            let fallback = CALayer()
            fallback.backgroundColor = NSColor.black.cgColor
            return fallback
        }

        let background = CAMetalLayer()
        background.device = device
        background.pixelFormat = .bgra8Unorm
        background.framebufferOnly = true
        background.maximumDrawableCount = 2
        background.drawableSize = CGSize(width: 1, height: 1)
        background.contentsGravity = .resize
        background.backgroundColor = NSColor.black.cgColor
        background.isOpaque = true

        // Stretch one black pixel behind the page. AppKit manages the layer's
        // geometry, while the drawable stays 1x1 through display/scale changes.
        // Submit only when the backing is created: no timer, display link,
        // repeated GPU work, or main-thread wait for GPU completion.
        guard let queue = device.makeCommandQueue(),
              let drawable = background.nextDrawable(),
              let command = queue.makeCommandBuffer() else {
            AppLog.warn("web wallpaper: Metal background frame is unavailable")
            return background
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
            AppLog.warn("web wallpaper: Metal background encoder is unavailable")
            return background
        }
        encoder.endEncoding()
        command.addCompletedHandler { command in
            if command.status == .error {
                AppLog.warn("web wallpaper: Metal background frame failed: \(String(describing: command.error))")
            }
        }
        command.present(drawable)
        command.commit()
        return background
    }

    // The background never changes. Redrawing the view must not replace the
    // submitted surface; the web view and suspension poster own their layers.
    override func updateLayer() {}
}
