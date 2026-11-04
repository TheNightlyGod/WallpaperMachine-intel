import AppKit

/// The display facts a renderer display refresh reads, so two readings tell a
/// change the renderer can act on from one it cannot.
///
/// `DisplayDesc::all()` in the engine reads the active displays, the main one,
/// and each display's bounds, pixel size and refresh rate from CoreGraphics.
/// This reads AppKit's copy of the same facts: the screens in order (the first
/// is the main display), each one's display ID, frame, backing scale and
/// refresh rate. AppKit keeps it in-process and updates it before posting
/// `didChangeScreenParametersNotification`; each CoreGraphics getter is a
/// window-server round trip, and this is read for every notification. An XDR
/// display posts one for every frame of an EDR headroom ramp, and headroom,
/// like the Dock and menu bar's working area, is not in here.
struct DisplayConfiguration: Equatable, Sendable {
    struct Display: Equatable, Sendable {
        var id: UInt32
        var frame: CGRect
        var scale: CGFloat
        var refreshRate: Int
    }

    var displays: [Display]

    static func current() -> DisplayConfiguration {
        DisplayConfiguration(displays: NSScreen.screens.map { screen in
            Display(id: SystemDisplays.id(of: screen) ?? 0, frame: screen.frame,
                    scale: screen.backingScaleFactor, refreshRate: screen.maximumFramesPerSecond)
        })
    }
}
