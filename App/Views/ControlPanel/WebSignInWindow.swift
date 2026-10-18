import AppKit
import WebKit

/// A site whose own sign-in page `WebSignInWindowController` shows, and the cookies the app
/// takes from it once someone has signed in: the session, and for Steam the token that renews it.
struct WebSignInSite: Sendable {
    let title: String
    let signInURL: URL
    let cookieName: String
    let cookieDomains: Set<String>
    /// A second cookie taken along with the session when the page set one, and where it lives.
    var companionName: String?
    var companionDomains: Set<String> = []
    /// Whether a cookie value is a real session rather than a placeholder the page sets early.
    let accepts: @Sendable (String) -> Bool

    static var pixiv: WebSignInSite {
        WebSignInSite(
            title: String(localized: "Sign in to pixiv"),
            signInURL: URL(
                string: "https://accounts.pixiv.net/login?return_to=https%3A%2F%2Fwww.pixiv.net%2F&source=pc&view_type=page")!,
            cookieName: "PHPSESSID", cookieDomains: ["pixiv.net", ".pixiv.net", "www.pixiv.net"],
            accepts: PixivService.isSessionValue)
    }

    static var steam: WebSignInSite {
        WebSignInSite(
            title: String(localized: "Sign in to Steam"),
            signInURL: URL(string: "https://steamcommunity.com/login/home/?goto=")!,
            cookieName: "steamLoginSecure", cookieDomains: ["steamcommunity.com", ".steamcommunity.com"],
            companionName: "steamRefresh_steam", companionDomains: ["login.steampowered.com"],
            accepts: { SteamWebSession(cookie: $0) != nil })
    }
}

/// What a sign-in window took from the page: the session cookie, and the site's companion cookie
/// when it has one and the page set it.
struct WebSignInCookies: Equatable, Sendable {
    let session: String
    var companion: String?
}

/// A site's own sign-in page in a window of its own. The page runs in a private website data
/// store that disappears with the window, and the app reads exactly what the site names from it:
/// the session cookie, and its companion, once someone has signed in. The password, and anything else typed
/// into the page, stays between the page and the site.
@MainActor
final class WebSignInWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate,
    WKHTTPCookieStoreObserver
{
    /// The open window of each site, by cookie name.
    private static var current: [String: WebSignInWindowController] = [:]

    /// Runs after a sign-in window has closed, so the app can leave the Dock once no ordinary
    /// window is left.
    static var onClosed: (() -> Void)?

    /// Whether `window` is an open sign-in window.
    static func isOpen(_ window: NSWindow) -> Bool {
        current.values.contains { $0.window === window }
    }

    private let site: WebSignInSite
    private let webView: WKWebView
    private var continuation: CheckedContinuation<WebSignInCookies?, Never>?

    /// The session cookie alone, for a site without a companion.
    static func obtainCookie(for site: WebSignInSite) async -> String? {
        await obtainCookies(for: site)?.session
    }

    /// Opens the window and answers the cookies the site set, or nil once the window closes
    /// without a session. While the site's window is open, another call only brings it forward
    /// and answers nil at once, so a caller must not start a second sign-in.
    static func obtainCookies(for site: WebSignInSite) async -> WebSignInCookies? {
        if let open = current[site.cookieName] {
            open.showWindow(nil)
            return nil
        }
        let controller = WebSignInWindowController(site: site)
        current[site.cookieName] = controller
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                controller.continuation = continuation
                controller.showWindow(nil)
                controller.webView.load(URLRequest(url: site.signInURL))
            }
        } onCancel: {
            Task { @MainActor in controller.finish(nil) }
        }
    }

    /// Brings the site's open sign-in window forward; does nothing when none is open.
    static func bringToFront(_ site: WebSignInSite) { current[site.cookieName]?.showWindow(nil) }

    private init(site: WebSignInSite) {
        self.site = site
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let size = NSSize(width: 480, height: 720)
        webView = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: configuration)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = site.title
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 380, height: 520)
        window.contentView = webView
        ControlPanelWindow.moveToActiveSpace(window)
        window.center()
        super.init(window: window)
        window.delegate = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        configuration.websiteDataStore.httpCookieStore.add(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Answers the waiting caller once, then closes the window and lets the page's data go.
    private func finish(_ session: WebSignInCookies?) {
        guard let continuation else { return }
        self.continuation = nil
        if Self.current[site.cookieName] === self { Self.current[site.cookieName] = nil }
        webView.configuration.websiteDataStore.httpCookieStore.remove(self)
        webView.stopLoading()
        window?.delegate = nil
        close()
        Self.onClosed?()
        continuation.resume(returning: session)
    }

    private func lookForSession() async {
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        guard continuation != nil,
            let session = cookies.first(where: {
                $0.name == site.cookieName && site.cookieDomains.contains($0.domain) && site.accepts($0.value)
            })?.value
        else { return }
        // Steam sets its renewal cookie before the session, so both are in the same snapshot.
        let companion = site.companionName.flatMap { name in
            cookies.first { $0.name == name && site.companionDomains.contains($0.domain) }?.value
        }
        finish(WebSignInCookies(session: session, companion: companion))
    }

    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor in await self.lookForSession() }
    }

    func windowWillClose(_ notification: Notification) {
        finish(nil)
    }

    // Anything but HTTPS (an app link, a mail address) goes nowhere; the window is for signing in.
    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        let scheme = navigationAction.request.url?.scheme?.lowercased()
        return scheme == "https" || scheme == "about" ? .allow : .cancel
    }

    // A page that opens a window of its own continues in this one instead.
    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.request.url?.scheme?.lowercased() == "https" { webView.load(navigationAction.request) }
        return nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        window?.subtitle = ""
        Task { await lookForSession() }
    }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error
    ) {
        showFailure(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showFailure(error)
    }

    /// A load the page itself replaced, or one refused above, is not a failure worth showing.
    private func showFailure(_ error: Error) {
        let error = error as NSError
        if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled { return }
        if error.domain == "WebKitErrorDomain", error.code == 102 { return }
        window?.subtitle = error.localizedDescription
    }
}
