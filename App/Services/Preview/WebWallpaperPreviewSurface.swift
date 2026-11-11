import AppKit
import WebKit

/// A disposable web page with its own storage and property delivery, separate from desktop pages.
@MainActor
final class WebWallpaperPreviewSurface: NSObject, WallpaperPreviewSurface, WKUIDelegate {
    let view: NSView
    let page: WebWallpaperPage
    var onReady: (() -> Void)?
    var onFailure: ((String) -> Void)?
    private let request: WallpaperPreviewRequest
    private let assets: UserAssetStore
    private var fetchAll = Set<String>()
    /// The staged copies of the files the page was handed, by property id. A later delivery
    /// names the user's own path again, so these are put back to keep the page's value.
    private var replacements: [String: String] = [:]
    private var stopped = false

    /// `inspectable` is read once: a preview lives for a few minutes at most, and
    /// the next one opened honors whatever the preference is by then.
    init(request: WallpaperPreviewRequest, generation: UInt64,
         counters: RuntimeCounters? = nil, assets: UserAssetStore? = nil,
         inspectable: Bool = WebWallpaperInspection.isEnabled()) {
        self.request = request
        self.assets = assets ?? UserAssetStore(projectURL: request.projectURL, wallpaperId: request.wallpaperID)
        page = WebWallpaperPage(projectURL: request.projectURL, entryFile: request.entryFile,
            surface: RuntimeSurfaceKey(kind: .preview, displayID: 0, generation: generation),
            counters: counters, persistentData: false, inspectable: inspectable)
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 960, height: 540))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.cgColor
        view = content
        super.init()
        page.webView.uiDelegate = self
        page.addUserScript(WKUserScript(
            source: Self.denyCaptureScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        page.attach(to: content)
        page.onLoaded = { [weak self] in
            guard let self, !stopped else { return }
            for property in fetchAll {
                page.deliverDirectoryFiles(property: property, added: self.assets.stagedFiles(propertyId: property).map(\.pageValue), removed: [])
            }
            onReady?()
        }
        page.onFailure = { [weak self] message in self?.onFailure?(message) }
        page.onRandomFileRequest = { [weak self] token, property in
            guard let self, !stopped else { return }
            page.deliverRandomFile(requestId: token, property: property,
                                   path: self.assets.randomFile(propertyId: property)?.pageValue ?? "")
        }
        self.assets.onDirectoryChanged = { [weak self] property, added, removed in
            guard let self, !stopped, fetchAll.contains(property) else { return }
            page.deliverDirectoryFiles(property: property, added: added.map(\.pageValue), removed: removed.map(\.pageValue))
        }
    }

    func start() async throws {
        guard !stopped else { throw CancellationError() }
        // Refuse before loading author code if whole-page mute is unavailable.
        guard WebWallpaperAudioOutput.apply(volume: request.volume, muted: true, to: page.webView).pageMute else {
            throw WallpaperPreviewFailure(message: String(localized: "WebKit cannot provide muted playback for this preview."))
        }
        replacements = [:]
        for property in WebWallpaperHost.pathProperties(in: request.propertiesJSON) {
            try Task.checkCancellation()
            guard !property.source.isEmpty else { continue }
            let source = URL(fileURLWithPath: property.source)
            switch property.kind {
            case .file:
                let file = try await assets.importFile(at: source, propertyId: property.id, filter: property.filter)
                replacements[property.id] = file.pageValue
            case .directory:
                _ = try await assets.importDirectory(at: source, propertyId: property.id, filter: property.filter,
                                                    limit: UserAssetStore.defaultDirectoryFileLimit)
                if property.fetchAll { fetchAll.insert(property.id) }
            }
        }
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        page.applyUserProperties(json: WebWallpaperHost.substituting(replacements, in: request.propertiesJSON) ?? request.propertiesJSON)
        page.applyGeneralProperties(fps: request.fps)
        page.setAudioResponseEnabled(false)
        page.setMediaIntegrationEnabled(false)
        page.load()
    }

    /// The page already hands its listener only the properties whose values changed.
    /// A web page has no Wallpaper Engine options.
    func applyEngineOptions(_ options: WallpaperEngineOptions) throws {}

    func applyProperties(_ json: String) throws {
        guard !stopped else { return }
        page.applyUserProperties(json: WebWallpaperHost.substituting(replacements, in: json) ?? json)
    }

    func setPaused(_ paused: Bool) throws {
        page.setPaused(paused)
        page.setPresentationSuspended(paused)
    }

    func setMuted(_ muted: Bool) throws {
        page.applyAudioOutput(volume: request.volume, muted: muted)
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        assets.onDirectoryChanged = nil
        assets.cancelImports()
        page.onLoaded = nil
        page.onFailure = nil
        page.onRandomFileRequest = nil
        page.stop()
        page.webView.uiDelegate = nil
        page.webView.removeFromSuperview()
        onReady = nil
        onFailure = nil
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) { decisionHandler(.deny) }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) { completionHandler() }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) { completionHandler(false) }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) { completionHandler(nil) }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) { completionHandler(nil) }

    private static let denyCaptureScript = """
      (() => {
        const deny = () => Promise.reject(new DOMException('Capture is disabled in previews', 'NotAllowedError'));
        if (navigator.mediaDevices) for (const key of ['getUserMedia', 'getDisplayMedia'])
          Object.defineProperty(navigator.mediaDevices, key, { value: deny, configurable: false, writable: false });
        for (const key of ['getUserMedia', 'webkitGetUserMedia'])
          Object.defineProperty(navigator, key, { value: (_constraints, _success, failure) => {
            if (typeof failure === 'function') failure(new DOMException('Capture is disabled', 'NotAllowedError'));
          }, configurable: false, writable: false });
      })();
      """
}
