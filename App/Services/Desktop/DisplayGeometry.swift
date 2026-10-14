import AppKit

/// Where a renderer display id lands on the attached screens, and what shape that screen has.
/// One lookup serves the image placement editor and the live preview window.
enum DisplayGeometry {
    /// The widest and narrowest shapes a preview stage takes; a rotated ultrawide stays a
    /// usable window instead of a sliver.
    static let aspectRange: ClosedRange<CGFloat> = 0.25...4

    /// The attached screen for a renderer display id (`primary`, a live CoreGraphics id, or
    /// an `identity:` selector) and its title, whose `(id - Role)` suffix carries the live id.
    /// `nil` when no attached screen has that id, for example a display that was unplugged.
    @MainActor static func screen(displayID: String, title: String) -> NSScreen? {
        guard let physicalID = ResolvedDisplayTitles.liveDisplayID(displayID, title: title) else { return nil }
        return NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == physicalID
        }
    }

    /// Width over height of the display, within `aspectRange`; `nil` when the screen is unknown.
    @MainActor static func aspectRatio(displayID: String, title: String) -> CGFloat? {
        screen(displayID: displayID, title: title).flatMap { aspectRatio(of: $0.frame.size) }
    }

    /// Width over height within `aspectRange`; `nil` for a size that has no shape.
    static func aspectRatio(of size: CGSize) -> CGFloat? {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return nil }
        return min(aspectRange.upperBound, max(aspectRange.lowerBound, size.width / size.height))
    }
}
