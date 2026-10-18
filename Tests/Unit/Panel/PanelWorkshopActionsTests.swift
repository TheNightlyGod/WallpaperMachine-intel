import XCTest

@testable import WallpaperMachine

/// What the panel accepts and shows for Discover: the lists, authors, collections, paging, the Steam
/// Community sign-in, and the update and reinstall requests. Steam is never reached: every request
/// fails at once, except the details of the one item a pasted link names, and the browse page for
/// one search text, which comes back as a page whose markup Steam has changed.
@MainActor
final class PanelWorkshopActionsTests: MediaPanelTestCase {
  private func makePanel() throws -> BrowsingPanel {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [OfflineProtocol.self]
    return try makeBrowsingPanel(service: WorkshopService(session: URLSession(configuration: configuration)))
  }

  private func search(_ panel: BrowsingPanel, _ text: String) async throws {
    try await panel.controller.searchWorkshop(
      text: text, sort: .trending, tags: [], excludedTags: ["Mature", "Application"])
    try await waitFor { !panel.workshop.isLoading && panel.workshop.hasLoaded }
  }

  func testAnAuthorOpensFromATileAndBackReturnsToTheList() async throws {
    let panel = try makePanel()
    let controller = panel.controller
    XCTAssertEqual(controller.workshopBrowse.source.source, .browse)
    XCTAssertTrue(controller.workshopBrowse.source.isSearchable)
    XCTAssertEqual(controller.workshopBrowse.source.list, .browse)

    for (id, name) in [
      ("123", "Too short"), ("7656119800000000x", "Letters"),
      ("76561198000000001", String(repeating: "n", count: 257)),
    ] {
      do {
        try await controller.openWorkshopAuthor(id: id, name: name)
        XCTFail("\(id) is not an author the panel can open")
      } catch is InvalidControlValue {}
    }
    try await controller.openWorkshopAuthor(id: "76561198000000001", name: "Fixture Author")
    var source = controller.workshopBrowse.source
    XCTAssertEqual(source.source, .creator(id: "76561198000000001", name: "Fixture Author"))
    XCTAssertEqual(source.name, "Fixture Author")
    XCTAssertFalse(source.isSearchable, "an author's list has no search field or sort menu")
    XCTAssertNil(source.list, "an opened author is none of the tabs")
    XCTAssertTrue(source.canGoBack)

    try await controller.workshopGoBack()
    source = controller.workshopBrowse.source
    XCTAssertEqual(source.source, .browse)
    XCTAssertFalse(source.canGoBack)

    try await controller.openWorkshopCollection(id: "3768533622", title: "Night skies")
    XCTAssertEqual(controller.workshopBrowse.source.source.key, "collection")
    for (id, title) in [("../3", ""), ("", "x"), (String(repeating: "9", count: 21), "x"), ("12", String(repeating: "t", count: 513))] {
      do {
        try await controller.openWorkshopCollection(id: id, title: title)
        XCTFail("\(id) is not a collection the panel can open")
      } catch is InvalidControlValue {}
    }
    try await controller.openWorkshop(.collections)
    XCTAssertEqual(controller.workshopBrowse.source.source, .collections)
    XCTAssertFalse(controller.workshopBrowse.source.canGoBack, "choosing a list starts the history over")
  }

  func testSubscriptionsSignInThroughSteamsPageAndSignOutForgetsTheSession() async throws {
    let panel = try makePanel()
    let controller = panel.controller
    try await controller.openWorkshop(.subscriptions)
    XCTAssertFalse(controller.workshopBrowse.isSignedInToSteam)

    var windows = 0
    controller.signInToSteamWeb = {
      windows += 1
      return WebSignInCookies(session: "76561198000000001%7C%7C0123456789abcdef0123")
    }
    try await controller.steamWebSignIn()
    await controller.steamWebSignInTask?.value
    XCTAssertTrue(controller.workshopBrowse.isSignedInToSteam)
    XCTAssertEqual(panel.workshop.steamWebSession?.steamID, "76561198000000001")
    XCTAssertEqual(windows, 1)

    try await controller.steamWebSignIn()
    XCTAssertEqual(windows, 1, "signed in, the action opens nothing")

    try await controller.steamWebSignOut()
    XCTAssertFalse(controller.workshopBrowse.isSignedInToSteam)
    XCTAssertTrue(controller.workshopBrowse.items.isEmpty, "the subscriptions list empties with the session")
  }

  func testASignInThatYieldsNoUsableSessionReachesTheBanner() async throws {
    let panel = try makePanel()
    panel.controller.signInToSteamWeb = { WebSignInCookies(session: "not a steam cookie") }
    try await panel.controller.steamWebSignIn()
    await panel.controller.steamWebSignInTask?.value
    XCTAssertEqual(
      panel.controller.errors.message,
      "Steam’s sign-in finished without a session this app can use. Try signing in again.")
    XCTAssertFalse(panel.controller.workshopBrowse.isSignedInToSteam)
  }

  func testACollectionIsOpenedNotDownloaded() async throws {
    let panel = try makePanel()
    let collection = WorkshopItem(
      id: "900", title: "Collection", creator: "Test", summary: "", previewURL: nil, tags: [], size: 0,
      subscriptions: 0, collectionSize: 4)
    panel.workshop.selectedItem = collection
    do {
      try await panel.controller.requestDownload(item: collection)
      XCTFail("a collection is not one download")
    } catch let error as WallpaperActionError {
      XCTAssertEqual(
        error.message, "A collection can’t be downloaded as one. Open it to download its wallpapers.")
    }
    XCTAssertTrue(panel.workshop.downloadRequests.isEmpty)
    XCTAssertNil(panel.workshop.downloader.download(for: "900"))
    XCTAssertEqual(panel.controller.workshopDoubleClick(for: collection), .openCollection)
    XCTAssertNil(panel.controller.workshopTile(for: collection).download, "a collection wears no ring")
  }

  /// The page says the sidebar does not apply only while the grid shows an item looked up from a
  /// pasted link, and not once something else has taken its place.
  func testTheStateFlagsTheItemLookedUpFromAPastedLink() async throws {
    let panel = try makePanel()
    let controller = panel.controller
    XCTAssertFalse(controller.workshopBrowse.isLookup)

    try await search(panel, "https://steamcommunity.com/sharedfiles/filedetails/?id=\(OfflineProtocol.itemID)")
    var browse = controller.workshopBrowse
    XCTAssertTrue(browse.isLookup)
    XCTAssertEqual(browse.items.map(\.id), [OfflineProtocol.itemID])
    XCTAssertEqual(browse.totalCount, 1)
    XCTAssertTrue(browse.steamURL.absoluteString.hasSuffix("id=\(OfflineProtocol.itemID)"))
    XCTAssertEqual(browse.lastSearch.sort, .trending)
    XCTAssertEqual(browse.lastSearch.excludedTags, ["Mature", "Application"])

    // A list that cannot be opened empties the grid, and the flag goes with the item.
    try await controller.openWorkshop(.collections)
    try await waitFor { !panel.workshop.isLoading }
    browse = controller.workshopBrowse
    XCTAssertFalse(browse.isLookup)
    XCTAssertTrue(browse.items.isEmpty)
    XCTAssertNotNil(browse.errorMessage, "the failed open says why, in the page and not the banner")
    XCTAssertNil(controller.errors.message)
  }

  /// The page says a list may be incomplete only while the grid shows one found from the links of a
  /// page whose markup changed, and not once another list has taken its place.
  func testTheStateFlagsAListFoundFromAPageSteamChanged() async throws {
    let panel = try makePanel()
    let controller = panel.controller
    XCTAssertFalse(controller.workshopBrowse.isDegraded)

    try await search(panel, OfflineProtocol.changedLayoutSearch)
    XCTAssertTrue(controller.workshopBrowse.isDegraded)
    XCTAssertTrue(controller.workshopBrowse.hasLoaded)
    XCTAssertEqual(controller.workshopBrowse.items.map(\.id), [OfflineProtocol.itemID])
    XCTAssertFalse(controller.workshopBrowse.isLookup)

    try await search(panel, "https://steamcommunity.com/sharedfiles/filedetails/?id=\(OfflineProtocol.itemID)")
    XCTAssertTrue(controller.workshopBrowse.isLookup)
    XCTAssertFalse(controller.workshopBrowse.isDegraded, "another list that opens takes the flag with it")

    try await search(panel, OfflineProtocol.changedLayoutSearch)
    XCTAssertTrue(controller.workshopBrowse.isDegraded)
    try await controller.openWorkshop(.collections)
    try await waitFor { !panel.workshop.isLoading }
    XCTAssertFalse(controller.workshopBrowse.isDegraded)
    XCTAssertTrue(controller.workshopBrowse.items.isEmpty)
  }

  func testASearchRefusesWhatNoControlOffers() async throws {
    let panel = try makePanel()
    let controller = panel.controller
    let tooMany = (0..<33).map { "tag\($0)" }
    let tooLong = String(repeating: "t", count: 129)
    let attempts: [(String, [String], [String])] = [
      ("", tooMany, []), ("", [tooLong], []), ("", [], (0..<65).map { "x\($0)" }), ("", [], [tooLong]),
      (String(repeating: "a", count: 65_537), [], []),
    ]
    for (text, tags, excluded) in attempts {
      do {
        try await controller.searchWorkshop(text: text, sort: .trending, tags: tags, excludedTags: excluded)
        XCTFail("a search with \(tags.count) tags and \(excluded.count) exclusions is stale")
      } catch is InvalidControlValue {}
    }
    XCTAssertEqual(panel.workshop.tags, [], "nothing of a refused search was stored")
    try await controller.searchWorkshop(
      text: "forest", sort: .newest, tags: Array(tooMany.prefix(32)), excludedTags: [tooLong.dropLast().description])
    XCTAssertEqual(panel.workshop.searchText, "forest")
    XCTAssertEqual(panel.workshop.sort, .newest)
    XCTAssertEqual(controller.workshopBrowse.lastSearch.tags.count, 32)
    panel.workshop.cancelSearch()
  }

  /// The sort menu offers every sort the store reads, and choosing one searches sorted by it.
  func testEveryWorkshopSortCanBeChosenAndSearchesSortedByIt() async throws {
    let panel = try makePanel()
    let labels = WorkshopSort.allCases.map(\.title)
    XCTAssertEqual(Set(labels).count, labels.count, "entries are told apart by their labels")
    XCTAssertFalse(labels.contains(where: \.isEmpty))
    XCTAssertEqual(Set(WorkshopSort.allCases.map(\.rawValue)).count, WorkshopSort.allCases.count)
    for sort in WorkshopSort.allCases {
      try await panel.controller.searchWorkshop(text: "", sort: sort, tags: [], excludedTags: [])
      XCTAssertEqual(panel.workshop.sort, sort)
      XCTAssertEqual(panel.controller.workshopBrowse.lastSearch.sort, sort)
    }
    panel.workshop.cancelSearch()
  }

  /// Steam clamps every public query to 1,000 pages of 30. A page past the end of the list, or
  /// outside Steam's limit, never moves the list off the pages it has (the typed number is clamped
  /// first, which `ResultPagerTests` pins).
  func testAPageOutsideTheListMovesNothing() async throws {
    let panel = try makePanel()
    let controller = panel.controller
    try await search(panel, OfflineProtocol.changedLayoutSearch)
    let pager = controller.workshopBrowse.pager
    XCTAssertEqual(pager.maxPages, 1000)
    XCTAssertEqual(WorkshopBrowseState.pageSize, 30, "a page is one Steam page, whatever the window's width")
    XCTAssertEqual(pager.pages, 1)
    XCTAssertFalse(pager.canJump)

    try await controller.showWorkshopPage(5000)
    try await controller.showWorkshopPage(-4)
    XCTAssertEqual(controller.workshopBrowse.pager.page, 1, "neither moved off the only page")
    XCTAssertEqual(controller.workshopBrowse.pager.totalPages, 1)
  }

  func testSelectingATileNeedsAnItemTheStoreKnows() async throws {
    let panel = try makePanel()
    let item = WorkshopItem(
      id: "111", title: "W111", creator: "Test", summary: "", previewURL: nil, tags: ["Video"], size: 2_048,
      subscriptions: 0)
    do {
      try await panel.controller.selectWorkshopItem(id: "111")
      XCTFail("an id the store does not know is a stale control")
    } catch is InvalidControlValue {}
    panel.workshop.selectedItem = item
    try await panel.controller.selectWorkshopItem(id: "111")
    XCTAssertEqual(panel.controller.workshopBrowse.selectedID, "111")
  }

  func testBrowsingLeavesAnOlderBannerShowing() async throws {
    let panel = try makePanel()
    panel.controller.errors.actionError = "An earlier failure"
    try await panel.controller.openWorkshop(.browse)
    try await panel.controller.retryWorkshopSearch()
    XCTAssertEqual(
      panel.controller.errors.message, "An earlier failure", "browsing leaves an older banner showing")
    panel.workshop.cancelSearch()
  }
}

/// Fails every request at once, so Discover never reaches Steam in these tests, except the details
/// of `itemID`, the one Workshop item a pasted link can name here.
private final class OfflineProtocol: URLProtocol, @unchecked Sendable {
  static let itemID = "3632513108"
  /// The search text whose browse page comes back with item links and no render context.
  static let changedLayoutSearch = "changed layout"

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    guard let url = request.url, let body = Self.body(for: url) else {
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

  private static func body(for url: URL) -> Data? {
    if url.host == "api.steampowered.com", url.path.contains("/ISteamRemoteStorage/GetPublishedFileDetails/") {
      let row: [String: Any] = [
        "publishedfileid": itemID, "result": 1, "consumer_app_id": 431960, "creator_app_id": 431960,
        "title": "Pasted item", "creator": "76561198000000001", "tags": [["tag": "Scene"], ["tag": "Mature"]],
        "file_size": "2048", "subscriptions": 3, "time_updated": 1_700_000_000,
      ]
      return try? JSONSerialization.data(withJSONObject: ["response": ["publishedfiledetails": [row]]])
    }
    let search = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
      .first { $0.name == "searchtext" }?.value
    if url.host == "steamcommunity.com", url.path.hasPrefix("/workshop/browse"), search == changedLayoutSearch,
      !(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains {
        $0.name == "section" && $0.value == "collections"
      } ?? false)
    {
      let link = "https://steamcommunity.com/sharedfiles/filedetails/?id=\(itemID)&searchtext="
      return Data("<html><body><a href=\"\(link)\"><img src=\"x\"></a></body></html>".utf8)
    }
    return nil
  }
}
