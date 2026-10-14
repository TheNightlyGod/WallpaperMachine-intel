import QuartzCore

/// The held picture: one still of what a display showed, carried as a plain sublayer of
/// whichever wallpaper window shows the next wallpaper.
///
/// A sublayer of the window's content layer and not a window of its own, so occlusion
/// tracking, hit testing, the poster sync (which reads renderer textures, never the screen)
/// and web snapshots (which render the page view) all see the window as before. It sits
/// above everything the window adds later through `zPosition`.
@MainActor
final class SwitchHoldVeil {
    static let layerName = "MWEHandoffVeil"
    static let fadeAnimationKey = "MWEHandoffVeilFade"

    let layer = CALayer()

    init(image: CGImage) {
        layer.name = Self.layerName
        layer.contents = image
        layer.contentsGravity = .resize
        layer.isOpaque = true
        layer.zPosition = 1_000
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        // The veil is only ever moved, shown and hidden: an implicit animation of any of these
        // would show the held picture sliding, cross-fading or popping instead of staying put.
        layer.actions = ["opacity": NSNull(), "contents": NSNull(), "bounds": NSNull(),
                         "position": NSNull(), "hidden": NSNull()]
    }

    /// The layer the veil sits on, if any.
    var parent: CALayer? { layer.superlayer }

    /// Whether the veil is on a layer at all.
    var isAttached: Bool { layer.superlayer != nil }

    /// Whether a fade-out has started.
    var isFading: Bool { layer.animation(forKey: Self.fadeAnimationKey) != nil }

    /// Puts the veil over `parent`, taking it off any layer it was on. `flush` commits the
    /// change to the render server at once, for a host window that is about to be ordered in:
    /// without it the window can reach the screen a frame before its veil. The renderer's
    /// layer announcement must not flush: it runs inside the renderer's own window operation.
    func attach(to parent: CALayer, flush: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: Self.fadeAnimationKey)
        layer.removeFromSuperlayer()
        layer.opacity = 1
        layer.frame = parent.bounds
        layer.contentsScale = parent.contentsScale
        parent.addSublayer(layer)
        CATransaction.commit()
        if flush { CATransaction.flush() }
    }

    /// Starts fading the veil out. The model value goes to zero at once, so a fade that never
    /// completes cannot leave the picture covering the wallpaper; the caller takes the veil
    /// off the layer with `detach()` after the duration.
    func beginFade(duration: TimeInterval) {
        let from = layer.presentation()?.opacity ?? layer.opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = 0
        CATransaction.commit()
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = 0
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(fade, forKey: Self.fadeAnimationKey)
    }

    /// Takes the veil off its layer for good.
    func detach() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAllAnimations()
        layer.removeFromSuperlayer()
        CATransaction.commit()
    }
}
