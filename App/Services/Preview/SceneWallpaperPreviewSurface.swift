import AppKit
import Metal
import QuartzCore

/// A private renderer attached to a regular view. It never creates a desktop window.
@MainActor
final class SceneWallpaperPreviewSurface: WallpaperPreviewSurface {
    final class RenderView: NSView {
        var resized: (() -> Void)?
        var pointer: ((CGPoint) -> Void)?
        var button: ((Int32, Bool) -> Void)?
        var entered: ((Bool) -> Void)?
        private var tracking: NSTrackingArea?
        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: .zero,
                options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
            addTrackingArea(area)
            tracking = area
        }
        private func move(_ event: NSEvent) {
            if let point = Self.normalized(convert(event.locationInWindow, from: nil), size: bounds.size) { pointer?(point) }
        }
        static func normalized(_ point: CGPoint, size: CGSize) -> CGPoint? {
            guard point.x.isFinite, point.y.isFinite, size.width.isFinite, size.height.isFinite,
                  size.width > 0, size.height > 0 else { return nil }
            return CGPoint(x: min(1, max(0, point.x / size.width)), y: min(1, max(0, 1 - point.y / size.height)))
        }
        override func mouseEntered(with event: NSEvent) { entered?(true); move(event) }
        override func mouseExited(with event: NSEvent) { entered?(false) }
        override func mouseMoved(with event: NSEvent) { move(event) }
        override func mouseDragged(with event: NSEvent) { move(event) }
        override func rightMouseDragged(with event: NSEvent) { move(event) }
        override func otherMouseDragged(with event: NSEvent) { move(event) }
        private func sendButton(_ event: NSEvent, pressed: Bool) {
            guard (0...31).contains(event.buttonNumber) else { return }
            move(event)
            button?(Int32(event.buttonNumber), pressed)
        }
        override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); sendButton(event, pressed: true) }
        override func mouseUp(with event: NSEvent) { sendButton(event, pressed: false) }
        override func rightMouseDown(with event: NSEvent) { sendButton(event, pressed: true) }
        override func rightMouseUp(with event: NSEvent) { sendButton(event, pressed: false) }
        override func otherMouseDown(with event: NSEvent) { sendButton(event, pressed: true) }
        override func otherMouseUp(with event: NSEvent) { sendButton(event, pressed: false) }
        override func layout() {
            super.layout()
            if !inLiveResize { resized?() }
        }
        override func viewDidEndLiveResize() { super.viewDidEndLiveResize(); resized?() }
        override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); resized?() }
    }

    private final class ReadyCallback: @unchecked Sendable {
        let ready: @MainActor @Sendable () -> Void
        init(_ ready: @escaping @MainActor @Sendable () -> Void) { self.ready = ready }
    }

    let view: NSView
    var onReady: (() -> Void)?
    var onFailure: ((String) -> Void)?
    private let request: WallpaperPreviewRequest
    private let cacheURL: URL
    private var metal: CAMetalLayer?
    private var renderer: OpaquePointer?
    private var muted = true
    private var paused = false
    private var stopped = false
    private var size: CGSize = .zero
    private var scale: CGFloat = 1
    private var resizing = false

    init(request: WallpaperPreviewRequest,
         cacheURL: URL = ClientPaths.supportURL.appendingPathComponent("ShaderCache/Previews", isDirectory: true)) {
        self.request = request
        self.cacheURL = cacheURL.appendingPathComponent(request.wallpaperID, isDirectory: true)
        let content = RenderView(frame: CGRect(x: 0, y: 0, width: 960, height: 540))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.cgColor
        view = content
        content.resized = { [weak self] in self?.resizeIfNeeded() }
        content.pointer = { [weak self] point in
            guard let self, !paused, let renderer else { return }
            _ = owe_scene_wallpaper_mouse_input(renderer, point.x, point.y)
        }
        content.button = { [weak self] button, pressed in
            guard let self, !paused, let renderer else { return }
            _ = owe_scene_wallpaper_mouse_button(renderer, button, pressed)
        }
        content.entered = { [weak self] entered in
            guard let self, let renderer else { return }
            _ = owe_scene_wallpaper_mouse_enter(renderer, entered && !paused)
            if !entered { _ = owe_scene_wallpaper_set_mouse_button_baseline(renderer, 0) }
        }
    }

    func start() async throws {
        guard !stopped, renderer == nil else { throw CancellationError() }
        try Task.checkCancellation()
        let cache = cacheURL
        try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        }.value
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        let layer = CAMetalLayer()
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw WallpaperPreviewFailure(message: String(localized: "Metal rendering is unavailable for this preview."))
        }
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.backgroundColor = NSColor.black.cgColor
        layer.isOpaque = true
        layer.framebufferOnly = true
        layer.frame = view.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        scale = view.window?.backingScaleFactor ?? 1
        size = pixelSize(scale: scale)
        layer.contentsScale = scale
        layer.drawableSize = size
        view.layer?.addSublayer(layer)
        metal = layer
        do {
            try check(owe_scene_wallpaper_new(&renderer))
            try check(owe_scene_wallpaper_init(renderer))
            try check(owe_scene_wallpaper_init_metal(renderer,
                Unmanaged.passUnretained(layer).toOpaque(), UInt32(size.width), UInt32(size.height), 0, 0, Double(scale)))
            let callback = Unmanaged.passRetained(ReadyCallback { [weak self] in
                guard let self, !self.stopped else { return }
                self.onReady?()
            }).toOpaque()
            let result = owe_scene_wallpaper_set_first_frame_callback(renderer, { pointer in
                guard let pointer else { return }
                let callback = Unmanaged<ReadyCallback>.fromOpaque(pointer).takeUnretainedValue()
                Task { @MainActor in callback.ready() }
            }, callback, { pointer in
                if let pointer { Unmanaged<ReadyCallback>.fromOpaque(pointer).release() }
            })
            if result != 0 { Unmanaged<ReadyCallback>.fromOpaque(callback).release() }
            try check(result)
            try check(owe_scene_wallpaper_set_property_bool(renderer, owe_property_audio_response_enabled(), false))
            try check(owe_scene_wallpaper_apply_config(renderer,
                request.projectURL.appendingPathComponent("project.json").path, request.assetsURL.path,
                cacheURL.path, request.fps, false, request.volume, muted, false, request.propertiesJSON))
            try check(owe_scene_wallpaper_set_property_bool(renderer, owe_property_media_integration_enabled(), false))
            try check(owe_scene_wallpaper_set_property_int32(renderer, owe_property_scaling_mode(), request.scalingMode))
            try check(owe_scene_wallpaper_set_property_float(renderer, owe_property_scaling_factor(), Float(request.scalingFactor)))
            if paused { try check(owe_scene_wallpaper_set_paused(renderer, true)) }
        } catch {
            stop()
            throw error
        }
    }

    func setPaused(_ paused: Bool) throws {
        self.paused = paused
        if let renderer {
            if paused { _ = owe_scene_wallpaper_set_mouse_button_baseline(renderer, 0) }
            try check(owe_scene_wallpaper_set_paused(renderer, paused))
        }
    }

    func setMuted(_ muted: Bool) throws {
        self.muted = muted
        if let renderer { try check(owe_scene_wallpaper_set_audio_muted(renderer, muted)) }
    }

    /// Hands the renderer the whole property state to show on the scene it is running. The
    /// renderer never saves it and holds what only a load can apply, such as a picture, at the
    /// value the scene loaded with.
    func applyProperties(_ json: String) throws {
        guard !stopped, let renderer else { return }
        try check(owe_scene_wallpaper_set_property_string(renderer, owe_property_project_property_preview_json(), json))
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        (view as? RenderView)?.resized = nil
        onReady = nil
        onFailure = nil
        if let renderer {
            // The renderer releases its swapchain before its CAMetalLayer can disappear.
            _ = owe_scene_wallpaper_begin_surface_reconfigure(renderer)
            _ = owe_scene_wallpaper_shutdown(renderer)
            _ = owe_scene_wallpaper_delete(renderer)
        }
        renderer = nil
        metal?.removeFromSuperlayer()
        metal = nil
    }

    private func pixelSize(scale: CGFloat) -> CGSize {
        CGSize(width: max(1, min(8192, (view.bounds.width * scale).rounded())),
               height: max(1, min(8192, (view.bounds.height * scale).rounded())))
    }

    private func resizeIfNeeded() {
        guard !stopped, !resizing, let renderer, let metal else { return }
        let nextScale = view.window?.backingScaleFactor ?? 1
        let nextSize = pixelSize(scale: nextScale)
        guard size != nextSize || scale != nextScale else { return }
        resizing = true
        defer { resizing = false }
        do {
            try check(owe_scene_wallpaper_begin_surface_reconfigure(renderer))
            metal.frame = view.bounds
            metal.contentsScale = nextScale
            metal.drawableSize = nextSize
            try check(owe_scene_wallpaper_finish_surface_reconfigure(renderer,
                Unmanaged.passUnretained(metal).toOpaque(), UInt32(nextSize.width), UInt32(nextSize.height),
                0, 0, Double(nextScale)))
            size = nextSize
            scale = nextScale
            try check(owe_scene_wallpaper_set_paused(renderer, paused))
        } catch { onFailure?(error.localizedDescription) }
    }

    private func check(_ result: Int32) throws {
        guard result != 0 else { return }
        let message = owe_last_error().map { String(cString: $0) }
            ?? String(localized: "The preview renderer could not start.")
        throw WallpaperPreviewFailure(message: message)
    }
}
