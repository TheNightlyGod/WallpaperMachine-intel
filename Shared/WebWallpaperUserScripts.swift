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
    /// Web workers are out of reach of a user script, so a worker's own `fetch`
    /// keeps WebKit's behaviour.
    static func userScripts(seed: Seed = Seed()) -> [WKUserScript] {
        [
            WKUserScript(source: compatScript, injectionTime: .atDocumentStart, forMainFrameOnly: false),
            WKUserScript(
                source: makeHostScript(seed: seed), injectionTime: .atDocumentStart, forMainFrameOnly: true),
        ]
    }
}
