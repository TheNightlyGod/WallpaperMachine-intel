import Foundation

/// The zoom steps of the panel's tile grids, counted from the standard size at 0: what the panel
/// stores and what a backup may restore.
enum TileZoom {
    static let steps: ClosedRange<Int> = -1...2

    /// `zoom` held to the steps there are.
    static func clamped(_ zoom: Int) -> Int {
        min(max(zoom, steps.lowerBound), steps.upperBound)
    }
}
