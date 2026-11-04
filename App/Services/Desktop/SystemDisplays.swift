import AppKit

/// The connected displays as Core Graphics numbers them, the id every display setting is keyed by.
enum SystemDisplays {
    static func id(of screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    static func screen(for displayID: UInt32) -> NSScreen? {
        NSScreen.screens.first { id(of: $0) == displayID }
    }

    static func screens() -> [(id: UInt32, frame: NSRect)] {
        NSScreen.screens.compactMap { screen in id(of: screen).map { ($0, screen.frame) } }
    }

    /// The display's maximum refresh rate in hertz, or 0 when it is not connected.
    static func refreshRate(of displayID: UInt32) -> Int {
        screen(for: displayID)?.maximumFramesPerSecond ?? 0
    }
}
