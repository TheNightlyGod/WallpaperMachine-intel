import XCTest

@testable import WallpaperMachine

/// "Download the ones not in your library": Steam is read for the signed-in account's subscriptions,
/// and only what the library lacks is requested. Steam is a fixture: a profile page that lists the
/// subscriptions and a details endpoint that describes them.
@MainActor
final class PanelWorkshopSubscriptionsTests: MediaPanelTestCase {
  private func makePanel(
    subscribed: [String: String], supportPrompt: SupportPromptStore? = nil
  ) throws -> BrowsingPanel {
    SubscriptionsProtocol.subscribed = subscribed
    addTeardownBlock {
      SubscriptionsProtocol.subscribed = [:]
      SubscriptionsProtocol.unreachable = false
    }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SubscriptionsProtocol.self]
    let panel = try makeBrowsingPanel(
      service: WorkshopService(session: URLSession(configuration: configuration)), supportPrompt: supportPrompt)
    panel.controller.signInToSteamWeb = { WebSignInCookies(session: "76561198000000001%7C%7C0123456789abcdef0123") }
    return panel
  }

  private func signIn(_ panel: BrowsingPanel) async throws {
    try await panel.controller.steamWebSignIn()
    await panel.controller.steamWebSignInTask?.value
  }

  private func installed(_ ids: [String]) -> BridgeLibrarySnapshot {
    BridgeLibrarySnapshot(
      wallpapers: ids.map {
        BridgeWallpaperEntry(
          id: $0, title: $0, kind: .video, supported: true, active: false, selected: false, previewPath: nil)
      },
      scanStatus: BridgeLibraryScanStatus(scanning: false, done: 0, total: 0), sceneCount: 0,
      videoCount: UInt64(ids.count), webpageCount: 0, unknownCount: 0)
  }

  /// The Workshop page marks the subscriptions of whoever is signed in now: after a sign-out and
  /// a new sign-in (here the same account), the next visit reads them again.
  func testTheWorkshopPageReadsTheMarksAgainForANewSignIn() async throws {
    let panel = try makePanel(subscribed: ["111": "Video"])
    try await panel.workshop.signInToSteamWeb {
      WebSignInCookies(session: "76561198000000001%7C%7C0123456789abcdef0123")
    }
    panel.controller.workshopBrowser.pageAppeared()
    try await waitFor { panel.workshop.subscribedIDs == ["111"] }

    panel.workshop.signOutOfSteamWeb()
    SubscriptionsProtocol.subscribed = ["222": "Video"]
    try await panel.workshop.signInToSteamWeb {
      WebSignInCookies(session: "76561198000000001%7C%7Cfedcba9876543210fedc")
    }
    panel.controller.workshopBrowser.pageAppeared()
    try await waitFor { panel.workshop.subscribedIDs == ["222"] }
  }

  /// A marks read that fails says so in the banner, naming what could not be read as well as
  /// Steam's reason, and the next visit to the page tries again.
  func testAFailedMarksReadIsReportedAndTriedAgainOnTheNextVisit() async throws {
    let panel = try makePanel(subscribed: ["111": "Video"])
    try await panel.workshop.signInToSteamWeb {
      WebSignInCookies(session: "76561198000000001%7C%7C0123456789abcdef0123")
    }
    SubscriptionsProtocol.unreachable = true
    panel.controller.errors.actionError = nil
    panel.controller.workshopBrowser.pageAppeared()
    try await waitFor { panel.controller.errors.actionError != nil }
    let message = try XCTUnwrap(panel.controller.errors.actionError)
    let reason = URLError(.notConnectedToInternet).localizedDescription
    XCTAssertTrue(message.hasSuffix(reason), "Steam's reason ends the line: \(message)")
    XCTAssertGreaterThan(message.count, reason.count, "the line also says what could not be read")
    XCTAssertEqual(panel.workshop.subscribedIDs, [])
    XCTAssertNotNil(panel.workshop.steamWebSession, "a connection failure keeps the sign-in")

    SubscriptionsProtocol.unreachable = false
    panel.controller.workshopBrowser.pageAppeared()
    try await waitFor { panel.workshop.subscribedIDs == ["111"] }
  }

  func testOnlyWhatTheLibraryLacksIsRequestedAndApplicationsAreSkipped() async throws {
    let panel = try makePanel(subscribed: ["111": "Video", "222": "Application", "333": "Scene", "444": "Video"])
    panel.store.librarySnapshot = installed(["111"])
    try await signIn(panel)
    panel.controller.errors.actionError = "An earlier failure"

    try await panel.controller.downloadSubscribedWorkshopItems()
    XCTAssertEqual(
      Set(panel.workshop.downloadRequests.map(\.id)), ["333", "444"],
      "111 is installed and 222 is an Application, which cannot run here")
    XCTAssertNil(panel.controller.errors.actionError, "asking clears an older banner first")
  }

  func testWhenNothingIsMissingTheActionSaysSo() async throws {
    let panel = try makePanel(subscribed: ["111": "Video"])
    panel.store.librarySnapshot = installed(["111"])
    try await signIn(panel)
    await panel.controller.launch("subscribed") {
      try await panel.controller.downloadSubscribedWorkshopItems()
    }.value
    XCTAssertEqual(
      panel.controller.errors.message, "Every wallpaper you subscribe to is already in your library.")
    XCTAssertTrue(panel.workshop.downloadRequests.isEmpty)
  }

  func testSignedOutTheSteamReadFailsAndTheSessionIsForgotten() async throws {
    let panel = try makePanel(subscribed: ["111": "Video"])
    await panel.controller.launch("subscribed") {
      try await panel.controller.downloadSubscribedWorkshopItems()
    }.value
    XCTAssertEqual(
      panel.controller.errors.message,
      "Steam asked you to sign in again. Sign in to Steam to see your subscriptions.")
    XCTAssertFalse(panel.controller.workshopBrowse.isSignedInToSteam)
  }

  func testTheRequestsWaitInTheCommandQueueAndTheSteamReadDoesNot() async throws {
    let panel = try makePanel(subscribed: ["333": "Scene"])
    try await signIn(panel)
    let gate = Gate()
    let held = Task { await panel.store.commands.run { await gate.wait() } }
    try await waitFor { panel.store.commands.isBusy }
    let subscribed = panel.controller.launch("subscribed") {
      try await panel.controller.downloadSubscribedWorkshopItems()
    }
    // Steam is read while another command holds the queue; only the requests wait for it.
    try await waitFor { !panel.store.commands.waiting.isEmpty }
    XCTAssertTrue(panel.workshop.downloadRequests.isEmpty, "the requests wait their turn")
    await gate.open()
    _ = await held.value
    await subscribed.value
    XCTAssertEqual(panel.workshop.downloadRequests.map(\.id), ["333"])
  }

  // MARK: Import my subscriptions

  /// The welcome guide's and the one-time offer's import signs in to Steam Community first, then
  /// queues what the library lacks. A sign-in window closed first changes nothing and leaves the
  /// offer open; signing in spends it, since whoever signed in found the feature.
  func testImportSignsInFirstThenQueuesWhatTheLibraryLacks() async throws {
    let prompt = SupportPromptStore(defaults: try TemporaryDefaults.make(for: self).defaults)
    let panel = try makePanel(subscribed: ["111": "Video", "333": "Scene"], supportPrompt: prompt)
    panel.store.librarySnapshot = installed(["111"])
    let signIn = panel.controller.signInToSteamWeb
    panel.controller.signInToSteamWeb = { nil }

    let closed = try await panel.controller.importSteamSubscriptions()
    XCTAssertNil(closed)
    XCTAssertTrue(panel.workshop.downloadRequests.isEmpty)
    XCTAssertEqual(prompt.pendingPrompt(welcomeSeen: true, telemetryOn: true, steamSignedIn: true), .subscriptions)

    panel.controller.signInToSteamWeb = signIn
    let queued = try await panel.controller.importSteamSubscriptions()
    XCTAssertEqual(queued, 1)
    XCTAssertEqual(panel.workshop.downloadRequests.map(\.id), ["333"])
    XCTAssertNil(prompt.pendingPrompt(welcomeSeen: true, telemetryOn: true, steamSignedIn: true))
  }

  /// The guide's card says what the import did: how many went to Downloads, or that the library
  /// already has them all.
  func testTheGuideReportsWhatTheImportQueued() async throws {
    let panel = try makePanel(subscribed: ["111": "Video", "333": "Scene"])
    panel.store.librarySnapshot = installed(["111"])
    let guide = panel.controller.welcome
    XCTAssertFalse(guide.isSignedInToSteamCommunity)
    await guide.importSubscriptions()
    XCTAssertEqual(guide.subscriptionImport, .queued(1))
    XCTAssertTrue(guide.isSignedInToSteamCommunity)
    XCTAssertNil(guide.error)

    panel.store.librarySnapshot = installed(["111", "333"])
    await guide.importSubscriptions()
    XCTAssertEqual(guide.subscriptionImport, .upToDate)
  }

  /// The offer to someone who never met the import: choosing it spends the offer at once, then the
  /// sign-in and the downloads run on without the sheet.
  func testTheOfferSpendsItselfAndImports() async throws {
    let prompt = SupportPromptStore(defaults: try TemporaryDefaults.make(for: self).defaults)
    let panel = try makePanel(subscribed: ["333": "Scene"], supportPrompt: prompt)
    try await panel.controller.supportPromptChoice(.importSubscriptions, for: .subscriptions)
    XCTAssertNil(prompt.pendingPrompt(welcomeSeen: true, telemetryOn: true, steamSignedIn: true))
    await panel.controller.steamWebSignInTask?.value
    XCTAssertEqual(panel.workshop.downloadRequests.map(\.id), ["333"])
    XCTAssertNil(panel.controller.errors.message)
  }
}

private actor Gate {
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  func wait() async {
    guard !isOpen else { return }
    await withCheckedContinuation { waiters.append($0) }
  }
  func open() {
    isOpen = true
    for waiter in waiters { waiter.resume() }
    waiters = []
  }
}

/// Steam: the subscriptions profile page of one account, and the details of any item asked about.
private final class SubscriptionsProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var subscribed: [String: String] = [:]
  /// The subscriptions page cannot be reached while this is set.
  nonisolated(unsafe) static var unreachable = false

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = request.url, let body = Self.body(for: url, request: request) else {
      client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
      return
    }
    client?.urlProtocol(
      self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!,
      cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: body)
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}

  private static func body(for url: URL, request: URLRequest) -> Data? {
    if url.host == "steamcommunity.com", url.path.contains("myworkshopfiles") {
      if unreachable { return nil }
      // Without the session cookie Steam shows its sign-in page.
      guard request.value(forHTTPHeaderField: "Cookie")?.hasPrefix("steamLoginSecure=") == true else {
        return Data("<html><head><title>Sign In</title></head><body></body></html>".utf8)
      }
      let rows = subscribed.keys.sorted().map {
        "<div class=\"workshopItemSubscription \" id=\"Subscription\($0)\"></div>"
      }.joined()
      let count = subscribed.count
      return Data("<html><head><title>Steam Community</title></head><body>\(rows)Showing 1-\(count) of \(count) entries</body></html>".utf8)
    }
    if url.host == "api.steampowered.com", url.path.contains("/ISteamRemoteStorage/GetPublishedFileDetails/") {
      let stream = request.httpBodyStream
      var data = request.httpBody ?? Data()
      if data.isEmpty, let stream {
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
          let count = stream.read(&buffer, maxLength: buffer.count)
          if count <= 0 { break }
          data.append(buffer, count: count)
        }
      }
      let ids = String(decoding: data, as: UTF8.self).split(separator: "&").compactMap { field -> String? in
        let pair = field.split(separator: "=", maxSplits: 1)
        return pair.count == 2 && pair[0].hasPrefix("publishedfileids[") ? String(pair[1]) : nil
      }
      let rows: [[String: Any]] = ids.map { id in
        [
          "publishedfileid": id, "result": 1, "consumer_app_id": WorkshopApp.id, "title": "W\(id)",
          "tags": [["tag": subscribed[id] ?? "Video"]], "file_size": "2048", "subscriptions": 3,
          "time_updated": 1_700_000_000,
        ]
      }
      return try? JSONSerialization.data(
        withJSONObject: ["response": ["result": 1, "resultcount": rows.count, "publishedfiledetails": rows]])
    }
    return nil
  }
}
