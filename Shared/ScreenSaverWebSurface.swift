import AppKit
import WebKit

/// Live WebKit layer tree for a remotely hosted native wallpaper context.
@MainActor
final class ScreenSaverWebSurface: NSObject, WKNavigationDelegate, WKUIDelegate {
  enum Failure: LocalizedError {
    case invalidEntry, invalidProperties, unavailable, timedOut, noFrame, terminated, suspension
    var errorDescription: String? {
      switch self {
      case .invalidEntry: String(localized: "The web wallpaper entry or asset is outside its published folder.")
      case .invalidProperties: String(localized: "The published web wallpaper properties are invalid.")
      case .unavailable: String(localized: "This macOS version cannot host a live web wallpaper.")
      case .timedOut: String(localized: "The web wallpaper did not produce a frame in time.")
      case .noFrame: String(localized: "The web wallpaper frame is unavailable.")
      case .terminated: String(localized: "The web wallpaper stopped unexpectedly.")
      case .suspension: String(localized: "The web wallpaper could not suspend or resume playback.")
      }
    }
  }

  /// WebKit requires an in-window, visible view to submit live compositor updates.
  /// This scheduling host is never ordered into WindowServer or made key. Its
  /// frame view's layer is exported to CAContext, not displayed in an AppKit window.
  private final class SchedulingWindow: NSWindow {
    override var isVisible: Bool { true }
    override var occlusionState: NSWindow.OcclusionState { .visible }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
  }

  private final class MessageProxy: NSObject, WKScriptMessageHandler {
    weak var owner: ScreenSaverWebSurface?
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
      MainActor.assumeIsolated {
        guard message.frameInfo.isMainFrame else { return }
        owner?.receive(message.body)
      }
    }
  }

  let webView: WKWebView
  let entryURL: URL
  private let projectURL: URL
  private let readAccessURL: URL
  private let container: NSView
  private let window: SchedulingWindow
  /// The layer `attach(to:)` placed in the exported tree.
  private var exported: CALayer?
  private let proxy = MessageProxy()
  private var properties: [String: Any]
  private var propertiesJSON: String
  private var directories: [String: [String]] = [:]
  private var deliveredDirectories: [String: [String]] = [:]
  private var fetchAllDirectories: [String: [String]] {
    directories.filter { (properties[$0.key] as? [String: Any])?["mode"] as? String == "fetchall" }
  }
  private var pendingRandomReplies = 0
  private var fps: UInt32
  private var desiredPaused: Bool
  private(set) var isPaused = false
  private(set) var isReady = false
  private(set) var isStopped = false
  private var transitioning = false
  private var commitRevision: UInt64 = 0
  private var operation: Task<Void, Never>?
  private var deadline: Task<Void, Never>?
  private var firstReply: ((Error?) -> Void)?
  private var captures: [UUID: (Result<NSImage, Error>) -> Void] = [:]
  private var captureDeadlines: [UUID: Task<Void, Never>] = [:]
  private var suspensionReply: CheckedContinuation<Void, Error>?
  var onFrame: ((NSImage) throws -> Void)?
  var onFailure: ((Error) -> Void)?
  /// How long a pause or resume waits on the page itself (its properties, its media, the held
  /// frame) before going on without it. A page still busy then is not broken: a heavy page can take
  /// seconds to rebuild after a resume, more so when its WebKit process has reached its memory limit.
  private let pageWait: Duration = .seconds(5)
  /// How long WebKit's own suspend or resume of the page may take before the surface counts as broken.
  private let suspensionWait: Duration = .seconds(15)
  /// Whether the page has an audio listener registered.
  private var audioSubscribed = false
  /// Feeds a subscribed page silence while it plays; see `updateSilence()`.
  private var silence: Task<Void, Never>?
  /// How often silence reaches a subscribed page: the desktop's spacing for a quiet stretch.
  static let silenceInterval: Duration = .seconds(1)

  init(projectURL: URL, entryFile: String, readAccessURL: URL, size: CGSize,
       scale: CGFloat, propertiesJSON: String, fps: UInt32, paused: Bool) throws {
    guard fps > 0 else { throw Failure.invalidProperties }
    guard let entry = WebWallpaperProtocol.canonicalEntryURL(projectURL: projectURL, entryFile: entryFile),
      Self.contains(entry, in: readAccessURL),
      (try? entry.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    else { throw Failure.invalidEntry }
    entryURL = entry
    self.projectURL = projectURL.standardizedFileURL.resolvingSymlinksInPath()
    self.readAccessURL = readAccessURL.standardizedFileURL.resolvingSymlinksInPath()
    self.fps = fps
    desiredPaused = paused
    properties = try Self.validatedProperties(propertiesJSON, root: self.readAccessURL, project: self.projectURL)
    self.propertiesJSON = propertiesJSON
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.mediaTypesRequiringUserActionForPlayback = []
    configuration.preferences.inactiveSchedulingPolicy = .suspend
    configuration.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
    // File resources and ES modules are confined by loadFileURL's sandbox grant.
    // Unlike desktop pages, native saver content gets no universal file access.
    // Its `requestAnimationFrame` is held to the published frame rate as the desktop page's is,
    // so the lock screen and the screen saver draw no more often than the frame-rate limit
    // and the reduced rate on battery; `deliverCommitted` retunes it when that changes. It is
    // laid out in the display's device pixels like the desktop page; see `pageZoom` below.
    let seed = WebWallpaperProtocol.Seed(
      framePacing: true, frameLimit: WebWallpaperProtocol.frameLimit(forFPS: fps),
      screenScale: Double(scale))
    for script in WebWallpaperProtocol.userScripts(seed: seed) { configuration.userContentController.addUserScript(script) }
    configuration.userContentController.addUserScript(WKUserScript(
      source: Self.denyCaptureScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
    webView = WKWebView(frame: CGRect(origin: .zero, size: size), configuration: configuration)
    container = NSView(frame: CGRect(origin: .zero, size: size))
    window = SchedulingWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless,
                              backing: .buffered, defer: true)
    super.init()
    guard webView.responds(to: NSSelectorFromString("_setPageMuted:")),
      webView.responds(to: NSSelectorFromString("_setMediaCaptureEnabled:")),
      webView.responds(to: NSSelectorFromString("_suspendPage:")),
      webView.responds(to: NSSelectorFromString("_resumePage:")),
      webView.responds(to: NSSelectorFromString("_setOverrideDeviceScaleFactor:")),
      webView.responds(to: NSSelectorFromString("_close"))
    else { throw Failure.unavailable }
    Self.setInteger(webView, selector: "_setPageMuted:", value: 7)
    Self.setBool(webView, selector: "_setMediaCaptureEnabled:", value: false)
    // The exported layer is shown by the native host, while its scheduling window is never
    // ordered in. Window occlusion would throttle a visible exported page; the host owns
    // suspension through setPaused instead, as the desktop host does for its web views.
    let occlusionSelector = "_setWindowOcclusionDetectionEnabled:"
    if webView.responds(to: NSSelectorFromString(occlusionSelector)) {
      Self.setBool(webView, selector: occlusionSelector, value: false)
    }
    let selector = NSSelectorFromString("_setOverrideDeviceScaleFactor:")
    typealias SetScale = @convention(c) (AnyObject, Selector, CGFloat) -> Void
    unsafeBitCast(webView.method(for: selector), to: SetScale.self)(webView, selector, scale)
    // Wallpaper Engine lays a page out in device pixels, and so does the desktop
    // (`WebWallpaperProtocol.pageZoom(forBackingScale:)`); the lock screen shows the same layout.
    webView.pageZoom = WebWallpaperProtocol.pageZoom(forBackingScale: Double(scale))
    proxy.owner = self
    webView.configuration.userContentController.add(proxy, name: WebWallpaperProtocol.messageHandlerName)
    webView.navigationDelegate = self
    webView.uiDelegate = self
    webView.underPageBackgroundColor = .black
    webView.allowsMagnification = false
    webView.allowsBackForwardNavigationGestures = false
    window.isReleasedWhenClosed = false
    // The exported frame view would otherwise paint the window background behind the page.
    window.isOpaque = false
    window.backgroundColor = .clear
    window.colorSpace = .sRGB
    window.ignoresMouseEvents = true
    container.wantsLayer = true
    container.layer?.contentsScale = scale
    webView.wantsLayer = true
    webView.autoresizingMask = [.width, .height]
    container.addSubview(webView)
    window.contentView = container
    rebuildDirectories()
  }

  /// Puts the live page into `root`. AppKit keeps a view's backing layer in its window's own
  /// tree, so the content view's layer added anywhere else goes straight back and `root` would
  /// show nothing live. The frame view's layer is the top of that tree, and since the window
  /// is never ordered in, nothing else parents it.
  func attach(to root: CALayer) throws {
    guard let frame = container.superview else { throw Failure.unavailable }
    frame.wantsLayer = true
    frame.layoutSubtreeIfNeeded()
    guard let layer = frame.layer else { throw Failure.unavailable }
    layer.frame = root.bounds
    root.addSublayer(layer)
    CATransaction.flush()
    guard layer.superlayer === root else { throw Failure.unavailable }
    exported = layer
  }

  func start(completion: @escaping (Error?) -> Void) {
    guard !isStopped, firstReply == nil, !isReady else {
      completion(CancellationError())
      return
    }
    firstReply = completion
    armDeadline(seconds: 30)
    webView.loadFileURL(entryURL, allowingReadAccessTo: readAccessURL)
  }

  func update(propertiesJSON: String, fps: UInt32, paused: Bool) throws {
    guard !isStopped else { throw CancellationError() }
    guard fps > 0 else { throw Failure.invalidProperties }
    guard self.propertiesJSON != propertiesJSON || self.fps != fps else {
      setPaused(paused)
      return
    }
    properties = try Self.validatedProperties(propertiesJSON, root: readAccessURL, project: projectURL)
    self.propertiesJSON = propertiesJSON
    self.fps = fps
    desiredPaused = paused
    commitRevision &+= 1
    rebuildDirectories()
    reconcile()
  }

  func setPaused(_ paused: Bool) {
    guard desiredPaused != paused else { return }
    desiredPaused = paused
    commitRevision &+= 1
    updateSilence()
    reconcile()
  }

  /// Wallpaper Engine calls a page's audio listener on its fixed cadence whether or not anything is
  /// playing, and the desktop keeps a quiet stretch fed once a second. The lock screen captures no
  /// audio, so a subscribed page is fed silence on that spacing while it plays. A page that only
  /// starts its idle animation once the listener has been called (an audio visualiser that waits
  /// for the host's first spectrum) otherwise never moves off its first frame.
  private func updateSilence() {
    let wanted = audioSubscribed && isReady && !isStopped && !isPaused && !desiredPaused
    guard wanted != (silence != nil) else { return }
    silence?.cancel()
    silence = nil
    guard wanted else { return }
    silence = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        await self?.deliverSilence()
        do { try await Task.sleep(for: Self.silenceInterval) } catch { return }
      }
    }
  }

  private func deliverSilence() async {
    _ = try? await webView.callAsyncJavaScript(
      WebWallpaperProtocol.deliverAudioScript,
      arguments: ["bins": [Double](repeating: 0, count: 128)], in: nil, contentWorld: .page)
  }

  /// Brings the page to `desiredPaused`. Only WebKit's suspend or resume failing, or not answering
  /// within `suspensionWait`, fails the surface; what waits on the page is bounded by `pageWait`
  /// and skipped past, so a busy page is suspended or resumed all the same.
  private func reconcile() {
    guard isReady, !isStopped, !transitioning else { return }
    transitioning = true
    operation = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        if self.isPaused {
          try await self.changePageSuspension(false, within: self.suspensionWait)
          guard !self.isStopped else { return }
          self.isPaused = false
          _ = try await self.bounded(self.pageWait) {
            await self.webView.setAllMediaPlaybackSuspended(false)
          }
        }
        let revision = self.commitRevision
        let pause = self.desiredPaused
        _ = try await self.bounded(self.pageWait) { try await self.deliverCommitted(paused: pause) }
        guard !self.isStopped else { return }
        if pause {
          _ = try await self.bounded(self.pageWait) {
            await self.webView.setAllMediaPlaybackSuspended(true)
          }
          // A page too busy to be captured keeps the frame it was last held with.
          if let image = try? await self.capture(), !self.isStopped { try? self.onFrame?(image) }
          guard !self.isStopped else { return }
          try await self.changePageSuspension(true, within: self.suspensionWait)
          guard !self.isStopped else { return }
          self.isPaused = true
        }
        self.transitioning = false
        self.updateSilence()
        if revision != self.commitRevision { self.reconcile() }
      } catch { if !self.isStopped { self.fail(error) } }
    }
  }

  /// Whichever of an operation and its time limit ended first.
  private final class Once { var done = false }

  /// `operation`'s result, or nil once `limit` has passed without one; the operation is left to
  /// finish on its own. What it throws within the limit is rethrown.
  private func bounded<T>(
    _ limit: Duration, _ operation: @escaping @MainActor () async throws -> T
  ) async throws -> T? {
    let once = Once()
    return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T?, Error>) in
      let timer = Task { @MainActor in
        try? await Task.sleep(for: limit)
        guard !once.done else { return }
        once.done = true
        continuation.resume(returning: nil)
      }
      Task { @MainActor in
        let result: Result<T, Error>
        do { result = .success(try await operation()) } catch { result = .failure(error) }
        guard !once.done else { return }
        once.done = true
        timer.cancel()
        continuation.resume(with: result.map { $0 })
      }
    }
  }

  private func deliverCommitted(paused: Bool) async throws {
    let currentDirectories = fetchAllDirectories
    let removed = deliveredDirectories.reduce(into: [String: [String]]()) { result, entry in
      let remaining = Set(currentDirectories[entry.key] ?? [])
      let missing = entry.value.filter { !remaining.contains($0) }
      if !missing.isEmpty { result[entry.key] = missing }
    }
    _ = try await webView.callAsyncJavaScript("""
      \(WebWallpaperProtocol.hostCall(.applyGeneralProperties, "general"));
      \(WebWallpaperProtocol.hostCall(.setFrameLimit, "limit"));
      \(WebWallpaperProtocol.hostCall(.applyUserProperties, "properties"));
      \(WebWallpaperProtocol.hostCall(.setPaused, "paused"));
      \(WebWallpaperProtocol.hostCall(.deliverMedia, "'status'", "{enabled:false}"));
      for (const [property, files] of Object.entries(removed))
        \(WebWallpaperProtocol.hostCall(.userDirectoryFilesRemoved, "property", "files"));
      for (const [property, files] of Object.entries(directories))
        \(WebWallpaperProtocol.hostCall(.userDirectoryFilesAddedOrChanged, "property", "files"));
      """, arguments: ["general": ["fps": Int(fps)], "limit": WebWallpaperProtocol.frameLimit(forFPS: fps),
                         "properties": properties,
                         "paused": paused, "directories": currentDirectories, "removed": removed], in: nil, contentWorld: .page)
    deliveredDirectories = currentDirectories
  }

  func snapshot(completion: @escaping (Result<NSImage, Error>) -> Void) {
    guard !isStopped, !isPaused else { completion(.failure(Failure.noFrame)); return }
    let id = UUID()
    captures[id] = completion
    captureDeadlines[id] = Task { @MainActor [weak self] in
      do { try await Task.sleep(for: .seconds(3)) } catch { return }
      self?.finishCapture(id, result: .failure(Failure.timedOut))
    }
    let configuration = WKSnapshotConfiguration()
    configuration.afterScreenUpdates = true
    webView.takeSnapshot(with: configuration) { [weak self] image, error in
      MainActor.assumeIsolated {
        self?.finishCapture(id, result: image.map { .success($0) } ?? .failure(error ?? Failure.noFrame))
      }
    }
  }

  private func capture() async throws -> NSImage {
    try await withCheckedThrowingContinuation { continuation in
      snapshot { continuation.resume(with: $0) }
    }
  }

  private func finishCapture(_ id: UUID, result: Result<NSImage, Error>) {
    captureDeadlines.removeValue(forKey: id)?.cancel()
    captures.removeValue(forKey: id)?(result)
  }

  private func changePageSuspension(_ suspended: Bool, within limit: Duration) async throws {
    guard try await bounded(limit, { try await self.changePageSuspension(suspended); return true }) != nil
    else { throw Failure.suspension }
  }

  private func changePageSuspension(_ suspended: Bool) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      suspensionReply = continuation
      let selector = NSSelectorFromString(suspended ? "_suspendPage:" : "_resumePage:")
      typealias Invoke = @convention(c) (AnyObject, Selector, @convention(block) (Bool) -> Void) -> Void
      let callback: @convention(block) (Bool) -> Void = { [weak self] success in
        MainActor.assumeIsolated {
          let reply = self?.suspensionReply
          self?.suspensionReply = nil
          if success { reply?.resume() } else { reply?.resume(throwing: Failure.suspension) }
        }
      }
      unsafeBitCast(webView.method(for: selector), to: Invoke.self)(webView, selector, callback)
    }
  }

  private func armDeadline(seconds: Int) {
    deadline?.cancel()
    deadline = Task { @MainActor [weak self] in
      do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
      self?.fail(Failure.timedOut)
    }
  }

  private func fail(_ error: Error) {
    guard !isStopped else { return }
    let reply = firstReply
    firstReply = nil
    stop()
    reply?(error)
    onFailure?(error)
  }

  func stop() {
    guard !isStopped else { return }
    isStopped = true
    isReady = false
    deadline?.cancel()
    deadline = nil
    operation?.cancel()
    operation = nil
    silence?.cancel()
    silence = nil
    let reply = firstReply
    firstReply = nil
    reply?(CancellationError())
    for id in Array(captures.keys) { finishCapture(id, result: .failure(CancellationError())) }
    suspensionReply?.resume(throwing: CancellationError())
    suspensionReply = nil
    proxy.owner = nil
    webView.configuration.userContentController.removeScriptMessageHandler(forName: WebWallpaperProtocol.messageHandlerName)
    webView.navigationDelegate = nil
    webView.uiDelegate = nil
    webView.removeFromSuperview()
    exported?.removeFromSuperlayer()
    exported = nil
    if webView.responds(to: NSSelectorFromString("_close")) { webView.perform(NSSelectorFromString("_close")) }
    window.contentView = nil
    window.close()
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard !isStopped, !isReady else { return }
    operation = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        try await self.deliverCommitted(paused: self.desiredPaused)
        // A broken optional image must not reject an otherwise rendered page.
        // Snapshot readiness still requires actual pixels after a paint turn.
        _ = try await self.webView.callAsyncJavaScript("""
          await Promise.allSettled(Array.from(document.images, image => image.decode()));
          await document.fonts.ready;
          await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
          """, arguments: [:], in: nil, contentWorld: .page)
        let image = try await self.capture()
        guard !self.isStopped else { return }
        try self.onFrame?(image)
        self.isReady = true
        self.deadline?.cancel()
        self.deadline = nil
        self.updateSilence()
        self.reconcile()
        let reply = self.firstReply
        self.firstReply = nil
        reply?(nil)
      } catch { if !self.isStopped { self.fail(error) } }
    }
  }

  func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
               decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    guard !isStopped, let url = action.request.url else { decisionHandler(.cancel); return }
    if action.targetFrame?.isMainFrame == true {
      decisionHandler(url.standardizedFileURL.resolvingSymlinksInPath() == entryURL ? .allow : .cancel)
    } else {
      decisionHandler(!url.isFileURL || Self.contains(url, in: readAccessURL) ? .allow : .cancel)
    }
  }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(error) }
  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail(error) }
  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { fail(Failure.terminated) }
  func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
               initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
               decisionHandler: @escaping (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
  func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
               initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) { completionHandler(nil) }
  func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
               initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) { completionHandler() }
  func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
               initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) { completionHandler(false) }
  func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
               initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) { completionHandler(nil) }

  func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
               for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }

  /// What the page posts, once `WebWallpaperProtocol.PageMessage` has checked it.
  private func receive(_ body: Any) {
    guard !isStopped, case .success(let message) = WebWallpaperProtocol.PageMessage.parse(body) else { return }
    switch message {
    case .audioSubscribed:
      audioSubscribed = true
      updateSilence()
    case .audioUnsubscribed:
      audioSubscribed = false
      updateSilence()
    case .randomFileRequest(let id, let property): receiveRandomFileRequest(id: id, property: property)
    case .mediaSubscribed, .mediaUnsubscribed, .pageDiagnostic: return
    }
  }

  private func receiveRandomFileRequest(id: String, property: String) {
    guard !isPaused, pendingRandomReplies < 32 else { return }
    let path = directories[property]?.randomElement() ?? ""
    pendingRandomReplies += 1
    Task { @MainActor [weak self] in
      guard let self else { return }
      defer { self.pendingRandomReplies -= 1 }
      guard !self.isStopped, !self.isPaused else { return }
      do {
        _ = try await self.webView.callAsyncJavaScript(
          WebWallpaperProtocol.hostCall(.deliverRandomFile, "id", "property", "path"),
          arguments: ["id": id, "property": property, "path": path], in: nil, contentWorld: .page)
      } catch { if !self.isStopped { self.fail(error) } }
    }
  }

  private func rebuildDirectories() {
    directories.removeAll()
    for (id, value) in properties {
      guard let property = value as? [String: Any], property["type"] as? String == "directory",
        let path = property["value"] as? String, !path.isEmpty,
        let url = Self.assetURL(path), Self.contains(url, in: readAccessURL),
        let children = try? FileManager.default.contentsOfDirectory(
          at: url, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
      else { continue }
      directories[id] = children.sorted { $0.path < $1.path }.prefix(2048).compactMap { child in
        guard Self.contains(child, in: readAccessURL),
          let values = try? child.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
          values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
        return Self.pagePath(child)
      }
    }
  }

  static func contains(_ url: URL, in root: URL) -> Bool {
    guard url.isFileURL, root.isFileURL, url.host == nil || url.host == "" || url.host == "localhost"
    else { return false }
    let components = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
    let base = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
    return components.count > base.count && Array(components.prefix(base.count)) == base
  }

  private static func assetURL(_ path: String) -> URL? {
    if path.hasPrefix("file:") { return URL(string: path) }
    let absolute = path.hasPrefix("/") ? path : "/" + path
    return URL(string: "file://" + absolute)
  }

  private static func pagePath(_ url: URL) -> String {
    String(url.absoluteString.dropFirst("file:///".count))
  }

  private static func validatedProperties(_ json: String, root: URL, project: URL) throws -> [String: Any] {
    guard let data = json.data(using: .utf8),
      var properties = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { throw Failure.invalidProperties }
    for (id, value) in properties {
      guard var property = value as? [String: Any],
        let type = property["type"] as? String, type == "file" || type == "directory",
        let path = property["value"] as? String, !path.isEmpty else { continue }
      let url: URL
      if let absolute = assetURL(path), contains(absolute, in: root) {
        url = absolute
      } else if !path.hasPrefix("/"), URL(string: path)?.scheme == nil,
        let relative = URL(string: path, relativeTo: URL(fileURLWithPath: project.path, isDirectory: true))?.absoluteURL,
        contains(relative, in: project)
      {
        url = relative
      } else {
        throw Failure.invalidEntry
      }
      guard FileManager.default.fileExists(atPath: url.path) else { throw Failure.invalidEntry }
      property["value"] = pagePath(url.standardizedFileURL.resolvingSymlinksInPath())
      properties[id] = property
    }
    return properties
  }

  private static func setInteger(_ view: WKWebView, selector name: String, value: UInt) {
    let selector = NSSelectorFromString(name)
    typealias Invoke = @convention(c) (AnyObject, Selector, UInt) -> Void
    unsafeBitCast(view.method(for: selector), to: Invoke.self)(view, selector, value)
  }
  private static func setBool(_ view: WKWebView, selector name: String, value: Bool) {
    let selector = NSSelectorFromString(name)
    typealias Invoke = @convention(c) (AnyObject, Selector, Bool) -> Void
    unsafeBitCast(view.method(for: selector), to: Invoke.self)(view, selector, value)
  }

  private static let denyCaptureScript = """
    (() => {
      const deny = () => Promise.reject(new DOMException('Capture is disabled in wallpaper presentation', 'NotAllowedError'));
      if (navigator.mediaDevices) {
        for (const key of ['getUserMedia', 'getDisplayMedia'])
          Object.defineProperty(navigator.mediaDevices, key, {value: deny, configurable: false, writable: false});
      }
      for (const key of ['getUserMedia', 'webkitGetUserMedia'])
        Object.defineProperty(navigator, key, {value: (_constraints, _success, failure) => {
          if (typeof failure === 'function') failure(new DOMException('Capture is disabled', 'NotAllowedError'));
        }, configurable: false, writable: false});
    })();
    """
}
