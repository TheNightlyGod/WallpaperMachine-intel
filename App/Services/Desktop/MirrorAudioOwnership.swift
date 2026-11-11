import Foundation

/// One display's wallpaper as far as being heard goes: what the activation rules decided for this
/// display, and the display whose assignment it plays (its own, or a mirror's source).
protocol MirroredAudioOutput {
    var paused: Bool { get }
    var muted: Bool { get }
    var volume: Float { get }
    var audioSourceDisplayId: UInt32 { get }
}

extension BridgeWebWallpaper: MirroredAudioOutput {}
extension BridgeNativeVideoWallpaper: MirroredAudioOutput {}

/// Mirrored displays share output responsibility, not mutable page or player state or audio
/// analysis: each mirror group is heard from one member, so its sound never plays twice.
enum MirrorAudioOwnership {
    /// The audible member of each group, keyed by the group's source display. The source itself when
    /// it can be heard, otherwise the lowest-numbered member that can, so a hidden source hands its
    /// sound to a visible mirror. Paused, muted and silent members and those that cannot present
    /// never own a group.
    static func owners<Output: MirroredAudioOutput>(
        in wallpapers: [UInt32: Output], canPresent: (UInt32) -> Bool
    ) -> [UInt32: UInt32] {
        var owners: [UInt32: UInt32] = [:]
        for (displayID, wallpaper) in wallpapers
        where !wallpaper.paused && !wallpaper.muted && wallpaper.volume > 0
            && wallpaper.volume.isFinite && canPresent(displayID) {
            let source = wallpaper.audioSourceDisplayId
            if let previous = owners[source] {
                if previous != source && (displayID == source || displayID < previous) {
                    owners[source] = displayID
                }
            } else {
                owners[source] = displayID
            }
        }
        return owners
    }
}
