import AppKit
import Darwin

/// Keeps a desktop web window's live surfaces in WindowServer transitions.
@MainActor
enum WebWallpaperWindowComposition {
    private typealias Connection = @convention(c) () -> Int32
    private typealias SetTags = @convention(c) (Int32, UInt32, UnsafePointer<UInt32>, Int32) -> Int32

    private struct API {
        let connection: Connection
        let setTags: SetTags

        init?() {
            guard let framework = dlopen(
                "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
            else { return nil }
            guard let connection = dlsym(framework, "SLSMainConnectionID"),
                  let setTags = dlsym(framework, "SLSSetWindowTags") else {
                dlclose(framework)
                return nil
            }
            self.connection = unsafeBitCast(connection, to: Connection.self)
            self.setTags = unsafeBitCast(setTags, to: SetTags.self)
            // Keep this single framework reference alive with its function pointers.
        }
    }

    private static let api = API()

    static func preserveLiveSurfaces(in window: NSWindow) {
        guard let api, let number = UInt32(exactly: window.windowNumber), number > 0 else {
            AppLog.warn("web wallpaper: live transition composition is unavailable")
            return
        }
        // kCGSNeverFlattenSurfacesDuringSwipesTagBit (55). A flattened transition
        // can hold the visible picture even while WebKit and Core Animation run.
        // Set only this bit; replacing the whole tag word would lose AppKit policy.
        // ABI/mechanism reference:
        // https://gist.github.com/avaidyam/d3c76df710651edbf4da56bad3fea9d2
        // Also verified against AppKit's _startLiveResize/_endLiveResize on macOS 27.
        let tags: [UInt32] = [0, 1 << 23]
        let result = api.setTags(api.connection(), number, tags, 64)
        if result != 0 {
            AppLog.warn("web wallpaper: live transition composition failed for window \(number): \(result)")
        }
    }
}
