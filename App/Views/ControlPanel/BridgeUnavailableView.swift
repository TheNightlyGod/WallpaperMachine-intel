import SwiftUI

/// What the control panel shows when the rendering bridge or the library could not start.
struct BridgeUnavailableView: View {
    let error: Error?
    /// Offered when the library's drive is missing: forget the drive and start over on this Mac.
    let useThisMac: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            if useThisMac != nil {
                Label("Wallpaper Library Unavailable", systemImage: "externaldrive.badge.exclamationmark")
            } else {
                Label("Bridge Unavailable", systemImage: "exclamationmark.triangle")
            }
        } description: {
            Text(verbatim: error?.localizedDescription ?? String(localized: "The rendering bridge could not be started."))
        } actions: {
            if let useThisMac {
                Button("Use This Mac Instead…", action: useThisMac)
            }
        }
        .frame(minWidth: 640, minHeight: 420)
    }
}
