import XCTest

@testable import WallpaperMachine

/// Everything the panel opens outside the app passes one allowlist; a link built from remote data
/// is only as safe as the host it names.
@MainActor
final class ExternalLinkTests: XCTestCase {
  func testEveryFixedLinkAndBuiltLinkThePanelOpensPassesTheAllowlist() throws {
    for link in ExternalLink.fixedLinks {
      XCTAssertTrue(ExternalLink.isAllowed(link), "\(link) must pass the external allowlist")
    }
    XCTAssertTrue(ExternalLink.fixedLinks.contains { $0.host == "help.steampowered.com" })
    let workshop = try XCTUnwrap(ExternalLink.workshopItem(id: "1234567890"))
    XCTAssertEqual(workshop.absoluteString, "https://steamcommunity.com/sharedfiles/filedetails/?id=1234567890")
    XCTAssertTrue(ExternalLink.isAllowed(workshop))
    let artwork = try XCTUnwrap(ExternalLink.pixivArtwork(id: "301"))
    XCTAssertEqual(artwork.absoluteString, "https://www.pixiv.net/artworks/301")
    XCTAssertTrue(ExternalLink.isAllowed(artwork))
    let issue = try XCTUnwrap(
      ExternalLink.newIssue(title: "[Scene] A & B", wallpaper: "1", version: "1.0", details: "**Type:** Scene"))
    XCTAssertTrue(ExternalLink.isAllowed(issue))
  }

  /// The report opens the bug form, whose required fields stay empty so the reporter has to say
  /// what they did, what went wrong and what they expected.
  func testAProblemReportFillsOnlyTheFormFieldsTheAppKnows() throws {
    let issue = try XCTUnwrap(
      ExternalLink.newIssue(
        title: "[Scene] A & B", wallpaper: "https://steamcommunity.com/sharedfiles/filedetails/?id=1",
        version: "1.5.9", details: "**Type:** Scene\n**Error:** x"))
    let components = try XCTUnwrap(URLComponents(url: issue, resolvingAgainstBaseURL: false))
    XCTAssertTrue(components.path.hasSuffix("/issues/new"))
    let fields = Dictionary(
      uniqueKeysWithValues: try XCTUnwrap(components.queryItems).map { ($0.name, $0.value ?? "") })
    XCTAssertEqual(
      fields,
      [
        "template": "bug_report.yml", "title": "[Scene] A & B",
        "wallpaper": "https://steamcommunity.com/sharedfiles/filedetails/?id=1", "version": "1.5.9",
        "app-details": "**Type:** Scene\n**Error:** x",
      ])
  }

  func testOnlyHttpsToAnExactHostWithoutCredentialsOrAPortIsAllowed() throws {
    for refused in [
      "file:///etc/passwd", "http://steamcommunity.com/", "ftp://github.com/", "javascript:alert(1)",
      "https://steamcommunity.com.example.net/", "https://notsteamcommunity.com/",
      "https://www.steamcommunity.com/", "https://evil.test/https://github.com/",
      "https://github.com@evil.test/", "https://user:password@github.com/",
      "https://github.com:8443/", "https://127.0.0.1/", "mwe-ui://app/index.html",
    ] {
      XCTAssertFalse(ExternalLink.isAllowed(try XCTUnwrap(URL(string: refused))), refused)
      XCTAssertNil(ExternalLink.allowed(refused), refused)
    }
    XCTAssertNotNil(ExternalLink.allowed("https://github.com/WallpaperMachine/WallpaperMachine/issues"))
    XCTAssertNotNil(ExternalLink.allowed("https://GitHub.com/x"), "hosts compare in lower case")
    XCTAssertNil(ExternalLink.allowed("not a url"))
  }

  func testIdsThatAreNotDigitsBuildNoLink() {
    for id in ["", "12 34", "12/../34", "abc", "１２３", "12\n"] {
      XCTAssertNil(ExternalLink.workshopItem(id: id), id)
      XCTAssertNil(ExternalLink.pixivArtwork(id: id), id)
    }
  }

  func testOpenReachesTheOpenerOnlyForAnAllowedLink() throws {
    var opened: [URL] = []
    let allowed = try XCTUnwrap(URL(string: "https://store.steampowered.com/mobile"))
    XCTAssertTrue(ExternalLink.open(allowed) { opened.append($0); return true })
    XCTAssertFalse(ExternalLink.open(try XCTUnwrap(URL(string: "https://evil.test/"))) { opened.append($0); return true })
    XCTAssertEqual(opened, [allowed])
    XCTAssertFalse(ExternalLink.open(allowed) { _ in false }, "a failed open is reported")
  }
}
