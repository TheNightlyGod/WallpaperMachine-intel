import Foundation

extension BridgeDisplaySettingsRow {
    /// Whether the display plays its own wallpaper rather than mirroring another or sitting out.
    var isIndependent: Bool { enabled && mode == .standalone }
}
