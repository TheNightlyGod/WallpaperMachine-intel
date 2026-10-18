import WebKit

extension WebWallpaperProtocol {
    /// Every user script a web wallpaper document gets, in the order they run,
    /// for the desktop page and the native screen-saver surface alike so the two
    /// cannot drift apart.
    ///
    /// The file-request fixes go into every frame, because a subframe the page
    /// embeds (an iframe of a project file, a `srcdoc` frame) fetches and loads
    /// project files too and would otherwise see WebKit's status 0. The host
    /// script, with the author API, the audio and media channels and the page's
    /// timing hooks, goes into the main frame only: a subframe is not the
    /// wallpaper, and must neither answer the host nor be asked by it.
    ///
    /// The font aliases (`WebWallpaperFontAliases`) go into every frame of a local page too,
    /// since a subframe sets text in the fonts it names as the wallpaper does, and so does
    /// `requestIdleCallback` (`WebWallpaperIdleCallbacks`), which Chromium has in every frame.
    ///
    /// The drag guard (`noDragScript`) goes into every frame too, local or remote,
    /// since an image or link in a subframe starts a drag as readily.
    ///
    /// Web workers are out of reach of a user script, so a worker's own `fetch`
    /// keeps WebKit's behaviour.
    static func userScripts(seed: Seed = Seed()) -> [WKUserScript] {
        [
            WKUserScript(source: compatScript, injectionTime: .atDocumentStart, forMainFrameOnly: false),
            WKUserScript(
                source: WebWallpaperIdleCallbacks.script, injectionTime: .atDocumentStart,
                forMainFrameOnly: false),
            WKUserScript(
                source: WebWallpaperFontAliases.script, injectionTime: .atDocumentStart,
                forMainFrameOnly: false),
            WKUserScript(source: noDragScript, injectionTime: .atDocumentStart, forMainFrameOnly: false),
            WKUserScript(
                source: makeHostScript(seed: seed), injectionTime: .atDocumentStart, forMainFrameOnly: true),
        ]
    }

    /// A wallpaper never starts a drag. The pointer events a desktop page gets are
    /// copies of ones Finder owns, so a drag WebKit began from them (an image, a
    /// link, selected text, a `draggable` element) dropped a copy of the picture
    /// onto the desktop and broke Finder's selection rectangle. Cancelling
    /// `dragstart` before any handler of the page's keeps WebKit from opening the
    /// system drag; the mouse events themselves still reach the page.
    static let noDragScript = """
    window.addEventListener("dragstart", event => event.preventDefault(), true);
    """
}
